# frozen_string_literal: true

# A guard for the ONE class of bug this suite is structurally blind to.
#
# Every example in every other spec file reaches the library through
# spec/spec_helper.rb, which requires all of it. A `.lic` does not: it names
# each lib in its own `load` block, and Lich runs it with nothing else in
# scope. So a script can use a constant it never loaded, every spec can pass,
# and the failure appears only in game, on the first line that touches it:
#
#   --- Lich: error: uninitialized constant UberCombat::LegSettings
#
# That is not hypothetical. It is exactly what `;uc-probe` did the first time
# anyone set `in_province_only`, because wiring the setting added a
# LegSettings call to uc-probe.lic without adding the matching load.
#
# This reads the scripts as TEXT rather than executing them. They cannot be
# required here at all -- they call SCRIPT_DIR, DRC, XMLData and Map at load
# time, none of which exist outside a game session, which is the whole reason
# the decision logic lives in lib/ and the scripts stay thin.
# A method rather than a constant: rubocop rightly refuses a constant defined
# inside a block, and the value is cheap enough to recompute.
def subproject_root
  File.expand_path("..", __dir__)
end

RSpec.describe "the .lic scripts" do
  # Which lib file defines each UberCombat constant a script might name. Built
  # from the source rather than hardcoded, so a new lib is covered the day it
  # is added and a renamed one cannot leave a stale entry behind.
  def constant_homes
    Dir[File.join(subproject_root, "lib", "*.rb")].each_with_object({}) do |path, homes|
      basename = File.basename(path, ".rb")
      File.read(path).scan(/^\s*(?:class|module)\s+([A-Z]\w*)/).flatten.each do |constant|
        homes[constant] ||= basename
      end
    end
  end

  # Only the FIRST segment matters. `UberCombat::Probe::Session` is satisfied
  # by whatever file defines Probe, because that file defines Session too.
  def constants_used(source)
    source.scan(/UberCombat::(\w+)/).flatten.uniq
  end

  def libs_loaded(source)
    source.scan(/load File\.join\(lib_dir, '([a-z_]+)\.rb'\)/).flatten
  end

  scripts = Dir[File.join(subproject_root, "*.lic")].sort

  it "finds scripts to check, so an empty glob cannot pass silently" do
    expect(scripts).not_to be_empty
  end

  scripts.each do |path|
    name = File.basename(path)

    it "#{name} loads a lib for every UberCombat constant it names" do
      source = File.read(path)
      loaded = libs_loaded(source)
      known = constant_homes

      missing = constants_used(source).filter_map do |constant|
        home = known[constant]
        next if home.nil? || loaded.include?(home)

        "#{constant} (defined in lib/#{home}.rb)"
      end

      expect(missing).to be_empty,
                         "#{name} uses #{missing.join(', ')} but does not load it. " \
                         "Add the load to the block at the top of the script."
    end

    # A load that nothing needs is dead weight rather than a defect, but it is
    # usually the fossil of a call that moved to another script, and it costs
    # a file read on every run.
    it "#{name} loads nothing it does not use" do
      source = File.read(path)
      known = constant_homes
      needed = constants_used(source).filter_map { |constant| known[constant] }.uniq

      expect(libs_loaded(source) - needed).to be_empty
    end
  end
end
