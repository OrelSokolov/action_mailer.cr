# RFC 5322 wire rendering for Mail::Message (headers + body).
# Deterministic parts only: boundary/date/message-id are injectable
# for tests; generated values otherwise.

require "base64"

class Mail::Message
  def rfc2822(boundary : String? = nil) : String
    String.build do |io|
      io << "From: " << (from.first? || "") << "\r\n"
      io << "To: " << (to.first? || "") << "\r\n"
      io << "Subject: " << (subject || "") << "\r\n"
      extra_headers.each { |k, v| io << k << ": " << v << "\r\n" }
      io << "MIME-Version: 1.0\r\n"
      io << "Content-Type: " << content_type_with_boundary(boundary) << "\r\n"
      io << "\r\n"

      if multipart?
        b = boundary || self.boundary
        parts.each do |part|
          io << "--" << b << "\r\n"
          io << "Content-Type: " << part.content_type << "\r\n\r\n"
          io << part.decoded << "\r\n"
        end
        attachments.each do |att|
          io << "--" << b << "\r\n"
          io << "Content-Type: " << att.mime_type << "; name=" << att.filename << "\r\n"
          io << "Content-Transfer-Encoding: " << att.content_transfer_encoding << "\r\n"
          io << "Content-Disposition: attachment; filename=" << att.filename << "\r\n\r\n"
          io << (att.content_transfer_encoding == "base64" ? Base64.encode(att.content) : att.content)
          io << "\r\n"
        end
        io << "--" << b << "--\r\n"
      else
        io << body.decoded << "\r\n"
      end
    end
  end

  private def content_type_with_boundary(boundary : String?) : String
    if multipart?
      "multipart/#{attachments.empty? ? "alternative" : "mixed"}; boundary=\"#{boundary || self.boundary}\""
    else
      content_type
    end
  end
end
