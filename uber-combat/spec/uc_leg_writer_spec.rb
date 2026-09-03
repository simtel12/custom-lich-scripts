# frozen_string_literal: true

require "tmpdir"
require "yaml"

# .decide is exercised first, with NO filesystem at all -- it takes the
# target file's first line (or nil) as a plain argument, exactly the point of
# separating it from .write (lib/uc_leg_writer.rb's own header comment). The
# .write examples below are the only ones that touch a real (temp) directory,
# and they exist to prove .write actually wires .decide's answer through to
# the one disk-writing method correctly -- not to re-test the decision logic
# itself.
RSpec.describe UberCombat::LegWriter do
  let(:overlay_no_gaps) do
    UberCombat::LegOverlay::Overlay.new(
      settings: { "weapon_training" => { "Brawling" => "" } },
      gaps: []
    )
  end

  let(:overlay_with_gaps) do
    UberCombat::LegOverlay::Overlay.new(
      settings: { "weapon_training" => {} },
      gaps: [{ skill: "Brawling", reason: :no_weapon_entry, detail: {} }]
    )
  end

  describe ".decide" do
    it "refuses any leg with a gap" do
      decision = described_class.decide(overlay_with_gaps, nil)

      expect(decision.write).to be false
      expect(decision.reason).to eq(:gaps)
      expect(decision.content).to be_nil
    end

    # Order matters (lib/uc_leg_writer.rb's own comment on .decide): a gap is
    # reported as a gap, never misreported as a foreign-file conflict, even
    # when a marker-carrying file already sits at the target.
    it "refuses a gapped leg even when the existing file already carries our marker" do
      decision = described_class.decide(overlay_with_gaps, described_class::MARKER)

      expect(decision.write).to be false
      expect(decision.reason).to eq(:gaps)
    end

    it "writes when no file exists at the target (nil first line)" do
      decision = described_class.decide(overlay_no_gaps, nil)

      expect(decision.write).to be true
      expect(decision.reason).to be_nil
      expect(decision.content).to start_with(described_class::MARKER)
    end

    it "writes when the existing file's first line is exactly our marker" do
      decision = described_class.decide(overlay_no_gaps, described_class::MARKER)

      expect(decision.write).to be true
      expect(decision.reason).to be_nil
    end

    it "refuses when the existing file's first line is not our marker" do
      decision = described_class.decide(overlay_no_gaps, "# hand-written, do not touch\n")

      expect(decision.write).to be false
      expect(decision.reason).to eq(:foreign_file)
      expect(decision.content).to be_nil
    end

    it "refuses when the existing file is empty (first line is \"\", not nil)" do
      decision = described_class.decide(overlay_no_gaps, "")

      expect(decision.write).to be false
      expect(decision.reason).to eq(:foreign_file)
    end

    it "content is the marker line followed by settings.to_yaml, nothing else" do
      overlay = UberCombat::LegOverlay::Overlay.new(
        settings: { "weapon_training" => { "Bow" => "steel bow" } },
        gaps: []
      )

      decision = described_class.decide(overlay, nil)

      expect(decision.content).to eq(described_class::MARKER + overlay.settings.to_yaml)
      # Round-trips back to the exact settings Hash -- the marker line is a
      # YAML comment and Psych skips it, so the file is still valid YAML.
      expect(YAML.safe_load(decision.content)).to eq(overlay.settings)
    end
  end

  describe ".write" do
    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    def target_path
      File.join(@dir, "Zurvan-uc.yaml")
    end

    it "writes the file when nothing exists at the target yet" do
      result = described_class.write(overlay_no_gaps, target_path)

      expect(result.written).to be true
      expect(result.path).to eq(target_path)
      expect(result.reason).to be_nil
      expect(File.read(target_path)).to eq(described_class::MARKER + overlay_no_gaps.settings.to_yaml)
    end

    it "overwrites a file that carries our marker" do
      File.write(target_path, described_class::MARKER + "stale: true\n")

      result = described_class.write(overlay_no_gaps, target_path)

      expect(result.written).to be true
      expect(File.read(target_path)).not_to include("stale: true")
    end

    it "refuses to overwrite a file with no marker, and leaves it byte-for-byte untouched" do
      original = "# a human wrote this\nfoo: bar\n"
      File.write(target_path, original)

      result = described_class.write(overlay_no_gaps, target_path)

      expect(result.written).to be false
      expect(result.reason).to eq(:foreign_file)
      expect(File.read(target_path)).to eq(original)
    end

    it "refuses a leg with gaps and creates no file at all" do
      result = described_class.write(overlay_with_gaps, target_path)

      expect(result.written).to be false
      expect(result.reason).to eq(:gaps)
      expect(File.exist?(target_path)).to be false
    end

    it "leaves no temp file behind after a successful write" do
      described_class.write(overlay_no_gaps, target_path)

      expect(Dir.glob(File.join(@dir, ".*.tmp"))).to be_empty
    end

    # Atomicity: a write that fails partway through must never leave a
    # partially written (or any) file visible at the target path, and must
    # not leak its temp file. Simulates the failure at the temp-file write
    # step, which is the earliest point real disk pressure (ENOSPC) or a
    # permissions problem could strike.
    it "leaves the target untouched and cleans up its temp file when the write fails" do
      allow(File).to receive(:write).and_call_original
      allow(File).to receive(:write).with(a_string_matching(/\.tmp\z/), anything).and_raise(Errno::ENOSPC)

      expect { described_class.write(overlay_no_gaps, target_path) }.to raise_error(Errno::ENOSPC)
      expect(File.exist?(target_path)).to be false
      expect(Dir.glob(File.join(@dir, ".*.tmp"))).to be_empty
    end
  end
end
