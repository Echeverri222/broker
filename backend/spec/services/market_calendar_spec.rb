require "rails_helper"

RSpec.describe MarketCalendar do
  def et(y, m, d, h, mi, s = 0) = ActiveSupport::TimeZone["America/New_York"].local(y, m, d, h, mi, s)

  {
    "weekday pre-open 09:29:59" => [ [ 2026, 3, 2, 9, 29, 59 ], false ],
    "open 09:30:00 [CAL-01]" => [ [ 2026, 3, 2, 9, 30, 0 ], true ],
    "last second 15:59:59" => [ [ 2026, 3, 2, 15, 59, 59 ], true ],
    "close 16:00:00 (exclusive)" => [ [ 2026, 3, 2, 16, 0, 0 ], false ],
    "Saturday" => [ [ 2026, 3, 7, 11, 0, 0 ], false ],
    "Sunday" => [ [ 2026, 3, 8, 11, 0, 0 ], false ],
    "New Year's 2026 [CAL-02]" => [ [ 2026, 1, 1, 11, 0, 0 ], false ],
    "Thanksgiving 2026 [CAL-02]" => [ [ 2026, 11, 26, 11, 0, 0 ], false ],
    "Christmas 2026 [CAL-02]" => [ [ 2026, 12, 25, 11, 0, 0 ], false ],
    "Good Friday 2027 [CAL-02]" => [ [ 2027, 3, 26, 11, 0, 0 ], false ],
    "early close 12:59:59 [CAL-03]" => [ [ 2026, 11, 27, 12, 59, 59 ], true ],
    "early close 13:00:00 [CAL-03]" => [ [ 2026, 11, 27, 13, 0, 0 ], false ],
    "Christmas Eve 2026 early close [CAL-03]" => [ [ 2026, 12, 24, 13, 0, 0 ], false ],
    "spring-forward day 2026-03-08 is Sunday; Monday after is open at 09:30 EDT [CAL-01]" => [ [ 2026, 3, 9, 9, 30, 0 ], true ],
    "fall-back Monday 2026-11-02 open at 09:30 EST [CAL-01]" => [ [ 2026, 11, 2, 9, 30, 0 ], true ]
  }.each do |name, (t, expected)|
    it "#{name} => open=#{expected}" do
      expect(described_class.status(et(*t))[:open]).to eq(expected)
    end
  end

  it "reports early_close and session in status [CAL-05]" do
    s = described_class.status(et(2026, 11, 27, 10, 0))
    expect(s).to include(open: true, session: "regular", early_close: true)
    expect(s[:next_close]).to eq(et(2026, 11, 27, 13, 0).utc.iso8601)
  end

  it "next_open skips a long weekend [CAL-02]" do
    # Friday 2026-05-22 after close -> Monday 05-25 is Memorial Day -> Tuesday 05-26
    expect(described_class.status(et(2026, 5, 22, 17, 0))[:next_open]).to eq(et(2026, 5, 26, 9, 30).utc.iso8601)
  end

  it "fails safe (closed, logged) past the end of the table [CAL-04]" do
    expect(Rails.logger).to receive(:error).with(/past the end of the table/)
    s = described_class.status(et(2028, 6, 6, 11, 0))
    expect(s).to include(open: false, next_open: nil)
  end

  it "covers at least 180 days ahead of today [CAL-04]" do
    expect(described_class::COVERED_THROUGH).to be >= Date.current + 180
  end

  it "uses Clock.now by default" do
    Clock.override = -> { Time.utc(2026, 3, 2, 16, 0, 0) }
    expect(described_class.open?).to be(true)
  end
end
