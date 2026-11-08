require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "masked_bonid keeps the prefix, last 3 characters and dashes" do
    assert_equal "DL-••••-•-••-•••••-C56", masked_bonid("DL-1988-M-OU-P8697-C56")
  end

  test "masked_bonid hides birth year, sex and department" do
    masked = masked_bonid("DL-1988-M-OU-P8697-C56")
    refute_includes masked, "1988"
    refute_match(/-M-/, masked)
    refute_includes masked, "OU"
  end

  test "masked_bonid handles blank and short values" do
    assert_equal "", masked_bonid(nil)
    assert_equal "", masked_bonid("")
    assert_equal "BON12", masked_bonid("BON12")
  end
end
