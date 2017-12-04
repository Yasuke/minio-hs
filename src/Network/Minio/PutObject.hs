--
-- Minio Haskell SDK, (C) 2017 Minio, Inc.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

module Network.Minio.PutObject
  (
    putObjectInternal
  , ObjectData(..)
  , selectPartSizes
  ) where


import qualified Data.Conduit as C
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.Combinators as CC
import qualified Data.Conduit.List as CL
import qualified Data.List as List

import           Lib.Prelude

import           Network.Minio.Data
import           Network.Minio.Errors
import           Network.Minio.S3API
import           Network.Minio.Utils


-- | A data-type to represent the source data for an object. A
-- file-path or a producer-conduit may be provided.
--
-- For files, a size may be provided - this is useful in cases when
-- the file size cannot be automatically determined or if only some
-- prefix of the file is desired.
--
-- For streams also, a size may be provided. This is useful to limit
-- the input - if it is not provided, upload will continue until the
-- stream ends or the object reaches `maxObjectsize` size.
data ObjectData m =
  ODFile FilePath (Maybe Int64) -- ^ Takes filepath and optional size.
  | ODStream (C.Producer m ByteString) (Maybe Int64) -- ^ Pass size in bytes as maybe if known.

-- | Put an object from ObjectData. This high-level API handles
-- objects of all sizes, and even if the object size is unknown.
putObjectInternal :: Bucket -> Object -> ObjectData Minio -> Minio ETag
putObjectInternal b o (ODStream src sizeMay) = sequentialMultipartUpload b o sizeMay src
putObjectInternal b o (ODFile fp sizeMay) = do
  hResE <- withNewHandle fp $ \h ->
    liftM2 (,) (isHandleSeekable h) (getFileSize h)

  (isSeekable, handleSizeMay) <- either (const $ return (False, Nothing)) return
                                 hResE

  -- prefer given size to queried size.
  let finalSizeMay = listToMaybe $ catMaybes [sizeMay, handleSizeMay]

  case finalSizeMay of
    -- unable to get size, so assume non-seekable file and max-object size
    Nothing -> sequentialMultipartUpload b o (Just maxObjectSize) $
               CB.sourceFile fp

    -- got file size, so check for single/multipart upload
    Just size ->
      if | size <= 64 * oneMiB -> either throwM return =<<
           withNewHandle fp (\h -> putObjectSingle b o [] h 0 size)
         | size > maxObjectSize -> throwM $ MErrVPutSizeExceeded size
         | isSeekable -> parallelMultipartUpload b o fp size
         | otherwise -> sequentialMultipartUpload b o (Just size) $
                        CB.sourceFile fp

parallelMultipartUpload :: Bucket -> Object -> FilePath -> Int64
                        -> Minio ETag
parallelMultipartUpload b o filePath size = do
  -- get a new upload id.
  uploadId <- newMultipartUpload b o []

  let partSizeInfo = selectPartSizes size

  -- perform upload with 10 threads
  uploadedPartsE <- limitedMapConcurrently 10
                    (uploadPart uploadId) partSizeInfo

  -- if there were any errors, rethrow exception.
  mapM_ throwM $ lefts uploadedPartsE

  -- if we get here, all parts were successfully uploaded.
  completeMultipartUpload b o uploadId $ rights uploadedPartsE
  where
    uploadPart uploadId (partNum, offset, sz) =
      withNewHandle filePath $ \h -> do
        let payload = PayloadH h offset sz
        putObjectPart b o uploadId partNum [] payload

-- | Upload multipart object from conduit source sequentially
sequentialMultipartUpload :: Bucket -> Object -> Maybe Int64
                          -> C.Producer Minio ByteString -> Minio ETag
sequentialMultipartUpload b o sizeMay src = do
  -- get a new upload id.
  uploadId <- newMultipartUpload b o []

  -- upload parts in loop
  let partSizes = selectPartSizes $ maybe maxObjectSize identity sizeMay
      (pnums, _, sizes) = List.unzip3 partSizes
  uploadedParts <- src
              C..| chunkBSConduit sizes
              C..| CL.map PayloadBS
              C..| uploadPart' uploadId pnums
              C.$$ CC.sinkList

  -- complete multipart upload
  completeMultipartUpload b o uploadId uploadedParts

  where
    uploadPart' _ [] = return ()
    uploadPart' uid (pn:pns) = do
      payloadMay <- C.await
      case payloadMay of
        Nothing -> return ()
        Just payload -> do pinfo <- lift $ putObjectPart b o uid pn [] payload
                           C.yield pinfo
                           uploadPart' uid pns
