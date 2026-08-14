# frozen_string_literal: true

require "json"

RSpec.describe CharBus::Protocol::Envelope do
  it "round-trips an envelope" do
    json = described_class.encode(
      type: "heartbeat_fast", from: "Drazoken", instance: "a3f9c1",
      seq: 7, payload: { "health" => 100 }
    )
    msg = described_class.decode(json)

    expect(msg[:v]).to eq(CharBus::Protocol::VERSION)
    expect(msg[:type]).to eq("heartbeat_fast")
    expect(msg[:from]).to eq("Drazoken")
    expect(msg[:instance]).to eq("a3f9c1")
    expect(msg[:seq]).to eq(7)
    expect(msg[:payload]).to eq({ "health" => 100 })
    expect(msg[:id]).to match(/\A[0-9a-f-]{36}\z/)
    expect(msg[:ts]).to be_a(Float)
  end

  it "puts reply_to in the envelope, not the payload" do
    json = described_class.encode(
      type: "request", from: "cli", instance: "x", seq: 1,
      reply_to: "dr:reply:abc", payload: { "verb" => "ping" }
    )
    raw = JSON.parse(json)

    expect(raw["reply_to"]).to eq("dr:reply:abc")
    expect(raw["payload"]).not_to have_key("reply_to")
  end

  it "omits reply_to when absent" do
    raw = JSON.parse(described_class.encode(type: "event", from: "a", instance: "b", seq: 1, payload: {}))
    expect(raw).not_to have_key("reply_to")
  end

  it "raises MalformedEnvelope on non-JSON" do
    expect { described_class.decode("{not json") }
      .to raise_error(CharBus::Protocol::MalformedEnvelope)
  end

  it "raises MalformedEnvelope when required keys are missing" do
    expect { described_class.decode('{"v":1}') }
      .to raise_error(CharBus::Protocol::MalformedEnvelope)
  end

  it "decodes a future version rather than rejecting it, so the caller can reply" do
    raw = JSON.parse(described_class.encode(type: "request", from: "cli", instance: "x", seq: 1, payload: {}))
    raw["v"] = 99
    msg = described_class.decode(JSON.generate(raw))
    expect(msg[:v]).to eq(99)
  end
end

RSpec.describe CharBus::Protocol::Channels do
  it "builds channel names from prefix and character" do
    expect(described_class.state("dr", "Drazoken")).to eq("dr:Drazoken_state")
    expect(described_class.requests("dr", "Drazoken")).to eq("dr:Drazoken_requests")
    expect(described_class.reply("dr", "abc-123")).to eq("dr:reply:abc-123")
  end

  it "normalizes a CLI-supplied character name to canonical casing" do
    expect(described_class.normalize_character("drazoken")).to eq("Drazoken")
    expect(described_class.normalize_character("DRAZOKEN")).to eq("Drazoken")
    expect(described_class.normalize_character("Drazoken")).to eq("Drazoken")
  end
end

RSpec.describe CharBus::Protocol::Sanitize do
  it "converts ASCII-8BIT game text to valid UTF-8" do
    binary = "orc\xE9 corpse".dup.force_encoding(Encoding::ASCII_8BIT)
    out = described_class.string(binary)

    expect(out.encoding).to eq(Encoding::UTF_8)
    expect(out).to be_valid_encoding
    expect(out).to eq("orc? corpse")
  end

  it "leaves clean UTF-8 untouched" do
    expect(described_class.string("a plain room")).to eq("a plain room")
  end

  it "does not mutate the input" do
    binary = "x\xE9".dup.force_encoding(Encoding::ASCII_8BIT)
    described_class.string(binary)
    expect(binary.encoding).to eq(Encoding::ASCII_8BIT)
  end

  it "sanitizes strings nested in hashes and arrays" do
    payload = { "title" => "a\xE9b".dup.force_encoding(Encoding::ASCII_8BIT),
                "pcs" => ["c\xE9d".dup.force_encoding(Encoding::ASCII_8BIT)] }
    out = described_class.deep(payload)

    expect(out["title"]).to eq("a?b")
    expect(out["pcs"]).to eq(["c?d"])
    expect { JSON.generate(out) }.not_to raise_error
  end

  it "leaves non-string scalars alone" do
    expect(described_class.deep({ "n" => 5, "f" => 1.5, "b" => true, "z" => nil }))
      .to eq({ "n" => 5, "f" => 1.5, "b" => true, "z" => nil })
  end
end
