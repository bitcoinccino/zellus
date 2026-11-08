require "test_helper"

class WalletsHelperTest < ActionView::TestCase
  # The case from the wallet page: 1.00738 USD at 135.50.
  # USD card shows 1.01 ≈ 136.86 HTG, so the total must be 136.86 / $1.01,
  # not 136.85 (floor) or 136.50 (unrounded balance).
  test "total equals the sum of the cards" do
    f = wallet_figures(htg: 0, usd: 1.00738, usd_htg: 135.5)

    assert_equal 101,   f[:usd]
    assert_equal 13686, f[:usd_in_htg]
    assert_equal 13686, f[:total_htg]
    assert_equal 101,   f[:total_usd]
  end

  test "mixed HTG and USD balances add up card by card" do
    f = wallet_figures(htg: 1234.567, usd: 2.004, usd_htg: 131.25)

    assert_equal 123457, f[:htg]
    assert_equal 941,    f[:htg_in_usd]     # 1234.57 / 131.25 = 9.406…
    assert_equal 200,    f[:usd]
    assert_equal 26250,  f[:usd_in_htg]
    assert_equal f[:htg] + f[:usd_in_htg], f[:total_htg]
    assert_equal f[:usd] + f[:htg_in_usd], f[:total_usd]
  end

  test "dust that displays as 0.00 adds nothing" do
    f = wallet_figures(htg: 0.004, usd: 0.004, usd_htg: 135.5)

    assert_equal 0, f[:total_htg]
    assert_equal 0, f[:total_usd]
  end

  test "cents_parts splits and delimits" do
    assert_equal [ "1,234", "05" ], cents_parts(123405)
    assert_equal [ "0", "00" ], cents_parts(0)
  end
end
