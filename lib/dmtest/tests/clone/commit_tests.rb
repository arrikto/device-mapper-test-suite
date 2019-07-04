require 'dmtest/utils'
require 'dmtest/blktrace'
require 'dmtest/disk-units'
require 'dmtest/thinp-test'
require 'dmtest/clone_stack'
require 'dmtest/clone_utils'

#----------------------------------------------------------------

#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# The periodic commit *may* interfere if the system is very heavily loaded.
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

# The kernel tracks if the dm-clone device has changed and only commits its
# metadata, triggered by a REQ_FLUSH or REQ_FUA, iff it has changed. These
# tests use blktrace on the metadata device to spot the superblock being
# rewritten in these cases.
class CommitTests < ThinpTestCase
  include Utils
  include BlkTrace
  include CloneUtils
  extend TestUtils

  def setup
    super

    @size = gig(1)
    @metadata_size = meg(16)

    check_dev_size(@metadata_dev, @data_dev, @size, @metadata_size)
  end

  def flush(dev)
    File.open(dev.path, "w") do |file|
      file.fsync
    end
  end

  def committed?(stack, flush, &block)
    # Make sure there are no pending commits.
    flush(stack.clone)

    traces, _ = blktrace(stack.md) do
      # FIXME: There is a race where the block might run before blktrace
      # starts. This will result in blktrace missing the write to the
      # superblock and the test failing.
      sleep 1

      block.call
      flush(stack.clone) if flush
    end

    traces[0].member?(Event.new([:write], 0, 8))
  end

  def assert_commit(stack, flush, &block)
    flunk("expected commit") unless committed?(stack, flush, &block)
  end

  def assert_no_commit(stack, &block)
    flunk("unexpected commit") if committed?(stack, true, &block)
  end

  def do_commit_checks(stack, flush, discard)
    # Force the first region to get hydrated
    assert_commit(stack, flush) do
      wipe_device(stack.clone, stack.region_size) if not discard
      stack.clone.discard(0, stack.region_size) if discard

      # The commit period in the kernel is 1 sec.
      sleep(2) if not flush
    end

    # The first region is hydrated now, so there shouldn't be a subsequent
    # commit.
    assert_no_commit(stack) do
      wipe_device(stack.clone, stack.region_size)
    end
  end

  define_test :commit_on_flush do
    s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => @size,
                       :metadata_size => @metadata_size, :hydration => false)

    # Test commits triggered by writing a block.
    s.activate do
      do_commit_checks(s, flush=true, discard=false)
    end

    # Test commits triggered by discarding a block.
    s.activate do
      do_commit_checks(s, flush=true, discard=true)
    end
  end

  define_test :commit_periodically do
    s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => @size,
                       :metadata_size => @metadata_size, :hydration => false)

    # Test periodic commits triggered by writing a block.
    s.activate do
      do_commit_checks(s, flush=false, discard=false)
    end

    # Test periodic commits triggered by discarding a block.
    s.activate do
      do_commit_checks(s, flush=false, discard=true)
    end
  end
end
