# frozen_string_literal: true

# Test double for the live DRSkill reader that UberCombat::Character consumes.
#
# It mirrors the real getmodrank contract deliberately:
# DRSkill.getmodrank is rank + exp_modifiers[name].to_i (drskill.rb:144-151),
# so an unmodified skill reports modrank == rank, NOT zero. The dr-scripts
# harness (dr-scripts/test/test_harness.rb:343-345) returns 0 for an unset
# modrank, which makes avg(getrank, getmodrank) read half the true value. This
# double does not repeat that.
class FakeSkills
  def initialize(ranks, modifiers = {})
    @ranks = ranks
    @modifiers = modifiers
  end

  def rank(name)
    @ranks.fetch(name, 0)
  end

  def modrank(name)
    rank(name) + @modifiers.fetch(name, 0)
  end
end
