# Mail core — minimal port of the ruby `mail` gem (2.9.1) semantics
# needed by ActionMailer P0: headers, single/multipart bodies,
# attachments, content-transfer-encoding. Encoded output for text
# bodies is a passthrough (oracle: UTF-8 bodies are sent as-is, no
# quoted-printable is applied when no explicit CTE was set).

module Mail
  class Field
    getter name : String
    getter value : String

    def initialize(@name, @value)
    end
  end

  class Body
    getter decoded : String

    def initialize(@decoded : String)
    end

    # Passthrough per mail 2.9.1 oracle behavior (uni_encoded case).
    def encoded : String
      @decoded
    end
  end

  class Part
    getter content_type : String # full, with charset param
    getter decoded : String

    def initialize(@content_type : String, @decoded : String)
    end

    def mime_type : String
      @content_type.split(';').first.strip
    end

    def charset : String
      "UTF-8"
    end
  end

  class Attachment
    getter filename : String
    getter mime_type : String
    getter content : String

    def initialize(@filename : String, @mime_type : String, @content : String)
    end

    def decoded : String
      @content
    end

    # mail 2.9.1: ASCII payload travels as 7bit, binary as base64.
    def content_transfer_encoding : String
      @content.each_char.all? { |c| c.ord < 128 } ? "7bit" : "base64"
    end
  end

  class Message
    getter parts : Array(Part)
    getter attachments : Array(Attachment)
    getter extra_headers : Hash(String, String)

    property subject : String?

    @from : String?
    @to : String?
    @body : Body?
    @top_mime : String?
    @single_content_type : String?
    @boundary : String?

    def initialize
      @parts = [] of Part
      @attachments = [] of Attachment
      @extra_headers = {} of String => String
    end

    # mail gem reads address fields as arrays
    def from : Array(String)
      @from ? [@from.not_nil!] : [] of String
    end

    def from=(v : String?) : String?
      @from = v
    end

    def to : Array(String)
      @to ? [@to.not_nil!] : [] of String
    end

    def to=(v : String?) : String?
      @to = v
    end

    def []=(name : String, value : String) : Nil
      @extra_headers[name] = value
    end

    def [](name : String) : Field
      if v = @extra_headers[name]?
        Field.new(name, v)
      else
        raise KeyError.new("header not found: #{name}")
      end
    end

    # --- assembly (called by ActionMailer::Base#mail) ------------------
    def set_single_body(body : String, content_type : String = "text/plain") : Nil
      @body = Body.new(body)
      @single_content_type = content_type
      @top_mime = content_type
    end

    def add_part(content_type : String, body : String) : Nil
      @parts << Part.new("#{content_type}; charset=UTF-8", body)
    end

    def add_attachment(filename : String, mime_type : String, content : String) : Nil
      @attachments << Attachment.new(filename, mime_type, content)
    end

    def set_multipart(mime : String) : Nil
      @top_mime = mime
    end

    # --- shape ----------------------------------------------------------
    def multipart? : Bool
      @parts.size > 1 || (!@attachments.empty? && !@body.nil?) || (!@attachments.empty? && !@parts.empty?)
    end

    def mime_type : String
      if multipart?
        @attachments.empty? ? "multipart/alternative" : "multipart/mixed"
      else
        @top_mime || "text/plain"
      end
    end

    def content_type : String
      if multipart?
        "#{mime_type}; boundary=\"#{boundary}\""
      else
        "#{mime_type}; charset=UTF-8"
      end
    end

    def charset : String
      "UTF-8"
    end

    def body : Body
      @body ||= begin
        if @parts.size == 1
          Body.new(@parts.first.decoded)
        else
          Body.new("")
        end
      end
    end

    def boundary : String
      @boundary ||= Random::Secure.hex(12)
    end
  end
end
