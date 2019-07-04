require 'dmtest/log'

#----------------------------------------------------------------

class CloneStatus
  attr_accessor :md_block_size, :md_used, :md_total, :region_size
  attr_accessor :nr_hydrated_regions, :nr_regions, :nr_hydrating_regions
  attr_accessor :features, :core_args, :mode

  PATTERN ='\d+\s+\d+\s+clone\s+(.*)'

  def initialize(dev)
    status = dev.status

    if status.match(/\s*Fail\s*/) or status.match(/\s*Error\s*/)
      @fail = true
    else
      m = status.match(PATTERN)
      raise "couldn't parse clone status" if m.nil?

      @a = m[1].split

      shift_int :md_block_size
      shift_ratio :md_used, :md_total
      shift_int :region_size
      shift_ratio :nr_hydrated_regions, :nr_regions
      shift_int :nr_hydrating_regions
      shift_features :features
      shift_pairs :core_args
      shift_mode :mode
    end
  end

  private
  def check_args(symbol)
    raise "Insufficient status fields, while trying to read #{symbol}" if @a.size == 0
  end

  def shift_(symbol)
    check_args(symbol)
    @a.shift
  end

  def shift(symbol)
    check_args(symbol)
    set_val(symbol, @a.shift)
  end

  def shift_int_(symbol)
    check_args(symbol)
    Integer(@a.shift)
  end

  def shift_int(symbol)
    check_args(symbol)
    set_val(symbol, Integer(@a.shift))
  end

  def shift_ratio(sym1, sym2)
    str = shift_(sym1)
    a, b = str.split('/')
    set_val(sym1, a.to_i)
    set_val(sym2, b.to_i)
  end

  def shift_features(symbol)
    r = Array.new
    n = shift_int_(symbol)

    if (n > 0)
      1.upto(n) do
        r << shift_(symbol)
      end
    end

    set_val(symbol, r)
  end

  def shift_pairs(symbol)
    r = Array.new

    n = shift_int_(symbol)
    raise "odd number of core arguments" if n.odd?

    if (n > 0)
      1.upto(n / 2) do
        key = shift_(symbol)
        value = shift_(symbol)
        r << [key, value]
      end
    end

    set_val(symbol, r)
  end

  def set_val(symbol, v)
    self.send("#{symbol}=".intern, v)
  end

  def shift_mode(symbol)
    case shift_(symbol)
    when 'ro' then
      set_val(symbol, :read_only)
    when 'rw' then
      set_val(symbol, :read_write)
    when 'Fail' then
      set_val(symbol, :Fail)
    else
      raise "unknown metadata mode"
    end
  end
end

#----------------------------------------------------------------
