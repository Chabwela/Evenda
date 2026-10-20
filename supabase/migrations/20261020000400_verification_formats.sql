-- Verification documents: accept the formats vendors actually have.
-- Phone photos (JPEG, PNG, WebP, iPhone HEIC/HEIF), scans as PDF, Word files.
-- Still refused: executables, archives, HTML and anything else, because staff
-- open these files on their phones. Limit stays 10 MB.
-- Mirrors kDocumentTypes in lib/design/widgets/photo_source.dart.
update storage.buckets
   set allowed_mime_types = array[
         'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif',
         'application/pdf',
         'application/msword',
         'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
       ],
       file_size_limit = 10485760
 where id = 'verification';
