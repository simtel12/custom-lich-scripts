# frozen_string_literal: true

# A zone table built from synthetic zones, for tests that must control bands
# exactly rather than depend on the committed data file.
class FakeZoneTable
  # The REAL predicate, not a copy and not a stub. ZonePicker#admissible? asks
  # the table whether a zone's critter bands are all known, and a double that
  # answered that more generously than production would let the rule pass every
  # test and still send a character to golden_atiket.
  include UberCombat::CritterBands

  attr_reader :zones, :critters

  def initialize(zones, critters = {})
    @zones = zones
    @critters = critters
  end

  def zone(key)
    @zones.find { |z| z.key == key }
  end
end
