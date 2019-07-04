#----------------------------------------------------------------

module CloneUtils
  include Utils

  def check_dev_size(fast_dev, slow_dev, volume_size, metadata_size)
    if dev_size(slow_dev) < volume_size
      raise "Slow device #{slow_dev} must be at least #{volume_size} sectors to run this class of tests"
    end

    if dev_size(fast_dev) < (volume_size + metadata_size)
      raise "Fast device #{fast_dev} must be at least #{volume_size + metadata_size} sectors to run this class of tests"
    end
  end

end

#----------------------------------------------------------------
