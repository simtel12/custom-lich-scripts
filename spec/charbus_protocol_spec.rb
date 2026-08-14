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
