# frozen_string_literal: true

# Invariants of the committed data file itself, not of any code path over it.
#
# These run against the real data/base-uc-zones.yaml through ZoneTable.load
# (DEFAULT_PATH), so they need no game runtime. Everything asserted here is
# true today. Nothing else in the suite would notice if a hand edit to the
# YAML broke it: the picker specs drive synthetic zones on purpose, and the
# integration spec asserts what the picker DOES with the data rather than
# whether the data still holds together.
#
# Every count is spelled out as its own named expectation. When one of these
# fails, the number in the example name is the number that used to be true,
# so a reader can tell a deliberate data addition from a regression without
# digging through history.
RSpec.describe UberCombat::ZoneTable, "committed data invariants" do
  subject(:table) { described_class.load(described_class::DEFAULT_PATH) }

  # A zone is judged on its critter_refs, not its critters: list. refs is the
  # bijection from in-game noun to critter record, and it is the map
  # CritterBands#critter_bands_known? and ZoneTable#critter_for both walk.
  def multi_critter_zones
    table.zones.select { |zone| zone.critter_refs.size >= 2 }
  end

  def critter_bands_of(zone)
    zone.critter_refs.each_value.map { |key| table.critters[key]["rank"] }
  end

  describe "the band of a multi-critter zone" do
    # For every multi-critter zone whose critters all carry a closed band, the
    # zone band IS the intersection of those bands: max of the mins, min of
    # the maxes. That is what makes the ordinary rank test in
    # ZonePicker#admissible? sufficient on its own -- the band already means
    # "the window in which no creature has dropped out", so no extra rule is
    # needed to keep a character out of a zone where half the roster has
    # stopped teaching.
    #
    # A hand edit that widens one of these bands past the intersection
    # silently reintroduces exactly the failure that CritterBands was added to
    # close, and it does so for a zone the picker considers perfectly healthy.
    # red-gold_atiket was one: it read 250-350 against an intersection of
    # 250-290 until it was corrected.
    it "is exactly the intersection of its critters' bands, for all 30 such zones" do
      closed = multi_critter_zones.select { |zone| table.critter_bands_known?(zone) }
      offenders = closed.reject do |zone|
        bands = critter_bands_of(zone)
        zone.rank_min == bands.map { |band| band["min"] }.max &&
          zone.rank_max == bands.map { |band| band["max"] }.min
      end

      expect(closed.size).to eq(30)
      expect(offenders.map(&:key)).to eq([]),
                                      "zone band is not the critter intersection for: " \
                                      "#{offenders.map(&:key).join(', ')}"
    end
  end

  # An inverted band is CORRECT DATA, not corruption. It is what the
  # intersection produces when the critters' bands do not overlap at all:
  # boar_boobrie_riverhaven reads 50-42 because the wild boar stops teaching
  # at 42 and the boobrie does not start until 50, so there is no rank at
  # which both still teach. Do not "repair" these by swapping the bounds or
  # by widening them to the union. The band is telling the truth, and the
  # zone excluding itself is the outcome the truth demands.
  describe "an inverted band" do
    let(:inverted) { table.zones.select { |zone| zone.closed_band? && zone.rank_max < zone.rank_min } }

    it "occurs in exactly 2 zones" do
      expect(inverted.map(&:key)).to contain_exactly("boar_boobrie_riverhaven", "qi_blood_wolves")
    end

    # The self-exclusion needs no code at all: rank_min <= rank <= rank_max
    # cannot hold for any rank once the bounds cross, so ZonePicker's ordinary
    # band test drops the zone for every skill and every character. Swept over
    # a range far wider than any real skill rank so the claim is about the
    # band, not about one character's numbers.
    it "can never be satisfied by any rank" do
      inverted.each do |zone|
        admitting = (0..2000).select { |rank| zone.rank_min <= rank && rank <= zone.rank_max }

        expect(admitting).to eq([]), "#{zone.key} admits rank(s) #{admitting.first}"
      end
    end

    it "is inverted only because its critters' bands do not overlap" do
      inverted.each do |zone|
        bands = critter_bands_of(zone)
        highest_start = bands.map { |band| band["min"] }.max
        earliest_end = bands.map { |band| band["max"] }.min

        expect(highest_start).to be > earliest_end,
                                 "#{zone.key} has overlapping critter bands, so its inverted " \
                                 "band is not explained by the intersection"
      end
    end
  end

  # Pinned counts. Each is its own example so a single moved number names
  # itself in the failure output instead of hiding behind an aggregate.
  describe "the shape of the table" do
    it "holds 363 zones" do
      expect(table.zones.size).to eq(363)
    end

    it "holds 306 critter records" do
      expect(table.critters.size).to eq(306)
    end

    # Escort zones are excluded from auto-selection rather than deleted: the
    # escort route is real and a later wave can use it. What is untrue is that
    # a hunt can be SENT to one unaided, because the key is not a room tag.
    it "marks 18 zones as escort access" do
      expect(table.zones.count(&:escort_access?)).to eq(18)
    end

    it "gives 36 zones two or more critters" do
      expect(multi_critter_zones.size).to eq(36)
    end

    # The 6 zones whose band cannot be trusted to mean "every creature here
    # still teaches", golden_atiket among them. If this number drops, a band
    # pass filled in the missing critter data and those zones became
    # selectable again, which is the intended direction of travel. If it
    # rises, a new zone arrived carrying the same hole.
    it "leaves 6 of those failing critter_bands_known?" do
      unknown = multi_critter_zones.reject { |zone| table.critter_bands_known?(zone) }

      expect(unknown.size).to eq(6)
      expect(unknown.map(&:key)).to include("golden_atiket")
    end

    # Single-critter zones are deliberately NOT judged: one creature cannot
    # diverge from itself, so its band is exactly as trustworthy as the
    # comment it came from. Counted here so the carve-out stays visible.
    it "leaves 5 single-critter zones with an unknown band, all of them admitted" do
      lone = table.zones.select { |zone| zone.critter_refs.size == 1 }
      unknown = lone.reject { |zone| critter_bands_of(zone).all? { |band| band["min"] && band["max"] } }

      expect(unknown.size).to eq(5)
      expect(unknown.map { |zone| table.critter_bands_known?(zone) }).to all(be(true))
    end
  end

  # critter_bands_known? reads table.critters[key] and treats a nil record as
  # an unknown band, so a dangling ref is handled rather than crashing. That
  # is the safe behaviour, but it also means a typo in a ref key would quietly
  # exclude a zone forever instead of being reported. No ref dangles today.
  it "resolves every critter ref in every zone to a real critter record" do
    dangling = table.zones.flat_map do |zone|
      zone.critter_refs.filter_map { |noun, key| "#{zone.key}/#{noun} -> #{key}" if table.critters[key].nil? }
    end

    expect(dangling).to eq([])
  end
end
