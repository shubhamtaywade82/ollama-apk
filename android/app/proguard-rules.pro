# pdfbox-android (PDF text extraction) references an optional JPEG 2000
# decoder for images inside PDFs. Text extraction never needs it, so it is
# not bundled; tell R8 the class is intentionally absent.
-dontwarn com.gemalto.jp2.JP2Decoder
