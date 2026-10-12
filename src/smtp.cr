# Minimal SMTP client (RFC 5321 subset): EHLO, MAIL FROM, RCPT TO,
# DATA, QUIT. STARTTLS/auth are P1 — plain local relay only.
# Not covered by the oracle (no SMTP server in the bench env); the
# protocol dialog is verified against a fake server in smtp_spec.
require "socket"

module ActionMailer
  class SmtpError < Exception; end

  class SmtpClient
    def initialize(@host : String, @port : Int32 = 25, @helo : String = "localhost")
    end

    def send(msg : Mail::Message) : Nil
      sock = TCPSocket.new(@host, @port)
      begin
        expect(sock, 220)
        cmd(sock, "EHLO #{@helo}", 250)
        cmd(sock, "MAIL FROM:<#{msg.from.first?}>", 250)
        msg.to.each do |rcpt|
          cmd(sock, "RCPT TO:<#{rcpt}>", 250)
        end
        cmd(sock, "DATA", 354)
        # Dot-stuffing per RFC 5321 §4.5.2
        stuffed = msg.rfc2822.split("\r\n").map do |line|
          line.starts_with?('.') ? ".#{line}" : line
        end.join("\r\n")
        sock << stuffed << "\r\n.\r\n"
        expect(sock, 250)
        sock << "QUIT\r\n"
      ensure
        sock.close
      end
    end

    private def cmd(sock : IO, command : String, code : Int32) : Nil
      sock << command << "\r\n"
      expect(sock, code)
    end

    private def expect(sock : IO, code : Int32) : String
      loop do
        line = sock.gets("\r\n") || raise SmtpError.new("connection closed")
        return line if line[0, 3].to_i == code && line[3]? != '-'
        raise SmtpError.new("unexpected reply: #{line}") if line[0, 3].to_i != code
      end
    end
  end
end

require "./rfc2822"
