# Single seam for "now". Tests and the e2e environment can override it.
module Clock
  class << self
    attr_writer :override

    def now = @override ? @override.call : Time.current
    def reset! = @override = nil
  end
end
