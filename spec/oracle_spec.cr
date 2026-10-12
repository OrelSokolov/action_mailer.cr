# Oracle spec: the Crystal port must reproduce oracle/expected.yml
# exactly (captured from actionmailer 8.1.4 + mail 2.9.1 via
# oracle/cases.rb). Same case IDs, same expectations, no edits.

require "spec"
require "../src/action_mailer_cr"

def spec_tmpdir : String
  dir = File.join(Dir.tempdir, "action_mailer_cr-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  dir
end

# Mirror of oracle/cases.rb line 22: everything below runs with the
# :test delivery method (the class default is :smtp, as in Rails).
ActionMailer::Base.delivery_method = :test

EXPECTED = begin
  hash = {} of String => String
  current_id : String? = nil
  File.read("#{__DIR__}/../oracle/expected.yml").each_line do |line|
    if line.includes?('\t')
      id, value = line.split('\t', 2)
      hash[id] = value.chomp
      current_id = id
    elsif cur = current_id
      hash[cur] = hash[cur] + "\n" + line.chomp
    end
  end
  hash
end

class BenchMailer < ActionMailer::Base
  default from: "noreply@example.com"

  def welcome_email(addr : String)
    mail(to: addr, subject: "Welcome!", body: "WELCOME BODY")
  end

  def plain_email(addr : String)
    mail(to: addr, subject: "Plain") do |format|
      format.text { "TEXT BODY" }
    end
  end

  def fancy_email(addr : String)
    mail(to: addr, subject: "Fancy") do |format|
      format.text { "TEXT BODY" }
      format.html { "<p>HTML BODY</p>" }
    end
  end

  def unicode_email(addr : String)
    mail(to: addr, subject: "Unicode") do |format|
      format.text { "Привет, мир!" }
    end
  end

  def with_attachment(addr : String)
    attachments["report.txt"] = {"mime_type" => "text/plain", "content" => "ATTACH DATA"}
    mail(to: addr, subject: "Attached", body: "SEE ATTACHED")
  end

  def custom_headers(addr : String)
    headers["X-Bench"] = "yes"
    mail(to: addr, subject: "hdr", body: "HDR BODY")
  end

  def param_email(addr : String)
    mail(to: addr,
      subject: "Hello #{params["user"]}",
      body: "PARAM BODY #{params["user"]}")
  end
end

WELCOME = BenchMailer.welcome_email("bob@example.com")
PLAIN   = BenchMailer.plain_email("bob@example.com")
FANCY   = BenchMailer.fancy_email("bob@example.com")
UNI     = BenchMailer.unicode_email("bob@example.com")
ATT     = BenchMailer.with_attachment("bob@example.com")
HDR     = BenchMailer.custom_headers("bob@example.com")
PARAM   = BenchMailer.with(user: "ann@example.com").param_email("bob@example.com")

ADAPTER = ActiveJob.adapter.as(ActiveJob::TestAdapter)

# Mirror of the oracle's custom delivery class (dm_custom).
class MarkerDelivery < ActionMailer::DeliveryMethod
  class_property delivered = [] of Mail::Message

  def deliver!(mail : Mail::Message) : Nil
    MarkerDelivery.delivered << mail
  end
end

CASES = {
  # --- DSL ---
  "dsl_from"           => -> { WELCOME.message.from.inspect },
  "dsl_to"             => -> { WELCOME.message.to.inspect },
  "dsl_subject"        => -> { WELCOME.message.subject.to_s },
  "dsl_content_type"   => -> { PLAIN.message.content_type },
  "dsl_body"           => -> { PLAIN.message.body.decoded },
  "dsl_headers"        => -> { HDR.message["X-Bench"].value },
  "dsl_delivery_class" => -> { WELCOME.class.name },
  # --- delivery (test method) ---
  "del_deliveries_size" => -> { WELCOME.deliver_now; ActionMailer::Base.deliveries.size.to_s },
  "del_last_subject"    => -> { ActionMailer::Base.deliveries.last.subject.to_s },
  "del_last_to"         => -> { ActionMailer::Base.deliveries.last.to.inspect },
  "del_now_returns"     => -> { PLAIN.deliver_now.class.name },
  # --- multipart ---
  "mp_multipart"    => -> { FANCY.message.multipart?.to_s },
  "mp_parts"        => -> { FANCY.message.parts.map(&.content_type).inspect },
  "mp_part_bodies"  => -> { FANCY.message.parts.map(&.decoded).inspect },
  "mp_top_ct"       => -> { FANCY.message.mime_type },
  # --- unicode body ---
  "uni_charset" => -> { UNI.message.charset },
  "uni_decoded" => -> { UNI.message.body.decoded },
  "uni_encoded" => -> { UNI.message.body.encoded },
  # --- attachments ---
  "att_multipart" => -> { ATT.message.multipart?.to_s },
  "att_top_ct"    => -> { ATT.message.mime_type },
  "att_names"     => -> { ATT.message.attachments.map(&.filename).inspect },
  "att_decoded"   => -> { ATT.message.attachments.map(&.decoded).inspect },
  "att_cte"       => -> { ATT.message.attachments.map(&.content_transfer_encoding).inspect },
  "att_mime"      => -> { ATT.message.attachments.map(&.mime_type).inspect },
  # --- deliver_later (ActiveJob test adapter: enqueue, no delivery) ---
  "dl_job_class"  => -> { BenchMailer.welcome_email("bob@example.com").deliver_later; ADAPTER.enqueued_jobs.last.job_class },
  "dl_args"       => -> { ADAPTER.enqueued_jobs.last.arguments.inspect },
  "dl_no_delivery" => -> { ActionMailer::Base.deliveries.size.to_s },
  "dl_scheduled"  => -> { BenchMailer.welcome_email("bob@example.com").deliver_later(wait: 5.minutes); ADAPTER.enqueued_jobs.last.scheduled_at ? "true" : "false" },
  # --- parameterized .with ---
  "with_subject"        => -> { PARAM.message.subject.to_s },
  "with_body"           => -> { PARAM.message.body.decoded },
  "with_to"             => -> { PARAM.message.to.inspect },
  "with_class"          => -> { PARAM.class.name },
  "with_params_default" => -> { BenchMailer.new.params.inspect },
  "with_deliver_now"    => -> { PARAM.deliver_now; ActionMailer::Base.deliveries.last.subject.to_s },
  "with_dl_job_class"   => -> { BenchMailer.with(user: "ann@example.com").param_email("bob@example.com").deliver_later; ADAPTER.enqueued_jobs.last.job_class },
  "with_dl_args"        => -> { ADAPTER.enqueued_jobs.last.arguments.inspect },
  # --- delivery methods (dm_*) ---
  "dm_custom" => -> {
    ActionMailer::Base.add_delivery_method(:marker, MarkerDelivery)
    ActionMailer::Base.delivery_method = :marker
    BenchMailer.welcome_email("dm@example.com").deliver_now
    MarkerDelivery.delivered.size.to_s
  },
  "dm_file" => -> {
    dir = spec_tmpdir
    ActionMailer::Base.delivery_method = :file
    ActionMailer::Base.delivery_settings(:file)["location"] = dir
    BenchMailer.welcome_email("file@example.com").deliver_now
    names = Dir.children(dir)
    [names.size, names.first,
     File.read(File.join(dir, names.first)).includes?("Subject: Welcome!")].inspect
  },
  "dm_smtp_swallowed" => -> {
    ActionMailer::Base.delivery_method = :smtp
    smtp = ActionMailer::Base.delivery_settings(:smtp)
    smtp["address"] = "127.0.0.1"
    smtp["port"] = 9
    ActionMailer::Base.raise_delivery_errors = false
    BenchMailer.welcome_email("x@example.com").deliver_now.class.name
  },
  "dm_unknown" => -> {
    begin
      ActionMailer::Base.raise_delivery_errors = true
      ActionMailer::Base.delivery_method = :nope
      BenchMailer.welcome_email("y@example.com").deliver_now
    ensure
      # Mirror of the delivery_method = :test restore at the end of
      # oracle/cases.rb (specs run lazily, so it must live here).
      ActionMailer::Base.delivery_method = :test
    end
  },
}

describe "action_mailer oracle (actionmailer 8.1.4 + mail 2.9.1)" do
  EXPECTED.each do |id, expected|
    it id do
      block = CASES[id]?
      block.should_not be_nil, "case #{id} not mirrored in spec"
      result = begin
        block.not_nil!.call.to_s
      rescue ex : Exception
        "raise:#{ex.class.name}"
      end
      result.strip.should eq(expected.strip), <<-MSG
        #{id}:
          expected: #{expected.inspect}
          got:      #{result.inspect}
        MSG
    end
  end

  it "mirrors every oracle case" do
    missing = EXPECTED.keys - CASES.keys
    extra = CASES.keys - EXPECTED.keys
    missing.should be_empty
    extra.should be_empty
  end
end
