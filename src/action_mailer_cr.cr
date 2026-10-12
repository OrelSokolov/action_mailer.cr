# action_mailer_cr — Crystal port of ActionMailer 8.1.4 (Iteration 5,
# P0: DSL + mail-core + :test delivery + minimal SMTP client;
# Phase D: delivery-method registry + Resend adapter).
require "base64"
require "active_support_cr"
require "active_job_cr"
require "./mail"
require "./base"
require "./parameterized"
require "./preview"
require "./preview_server"
require "./rfc2822"
require "./smtp"
require "./delivery"
require "./resend"
require "./mail_delivery_job"

module ActionMailer
  def self.deliveries : Array(Mail::Message)
    Base.deliveries
  end
end
