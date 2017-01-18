module Network.Minio.XmlParser
  ( parseListBuckets
  , parseLocation
  , parseNewMultipartUpload
  ) where

import Text.XML
import Text.XML.Cursor
import qualified Data.Text as T
import Data.Time

import           Lib.Prelude

import Network.Minio.Data

-- | Represent the time format string returned by S3 API calls.
s3TimeFormat :: [Char]
s3TimeFormat = iso8601DateFormat $ Just "%T%QZ"

-- | Parse the response XML of a list buckets call.
parseListBuckets :: (MonadError MinioErr m) => LByteString -> m [BucketInfo]
parseListBuckets xmldata = do
  doc <- either (throwError . MErrXml . show) return $ parseLBS def xmldata
  let cursor = fromDocument doc
      names = cursor $// element (s3Name "Bucket") &//
              element (s3Name "Name") &/ content
      timeStrings = cursor $// element (s3Name "Bucket") &//
                    element (s3Name "CreationDate") &/ content
  times <- either (throwError . MErrXml) return $
           mapM (parseTimeM True defaultTimeLocale s3TimeFormat . T.unpack)
           timeStrings
  return $ map (\(n, t) -> BucketInfo n t) $ zip names times

-- | Parse the response XML of a location request.
parseLocation :: (MonadError MinioErr m) => LByteString -> m Region
parseLocation xmldata = do
  doc <- either (throwError . MErrXml . show) return $ parseLBS def xmldata
  return $ T.concat $ fromDocument doc $/ content

-- | Parse the response XML of an newMultipartUpload call.
parseNewMultipartUpload :: (MonadError MinioErr m)
                        => LByteString -> m MultipartUpload
parseNewMultipartUpload xmldata = do
  doc <- either (throwError . MErrXml . show) return $ parseLBS def xmldata
  let cursor = fromDocument doc
      bucket = T.concat $ cursor $// element (s3Name "Bucket") &/ content
      object = T.concat $ cursor $// element (s3Name "Key") &/ content
      upId = T.concat $ cursor $// element (s3Name "UploadId") &/ content
  return $ MultipartUpload bucket object upId
