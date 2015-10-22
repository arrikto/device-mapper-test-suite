require 'dmtest/blktrace'
require 'dmtest/git'
require 'dmtest/log'
require 'dmtest/utils'
require 'dmtest/thinp-test'
require 'dmtest/cache-status'
require 'dmtest/disk-units'
require 'dmtest/test-utils'
require 'dmtest/tvm.rb'
require 'dmtest/cache_stack'
require 'dmtest/cache_policy'
require 'dmtest/cache_utils'

require 'thinp_xml/cache_xml'

#----------------------------------------------------------------

class BackgroundWritebackTests < ThinpTestCase
  include GitExtract
  include CacheUtils
  include BlkTrace
  extend TestUtils

  POLICY_NAMES = %w(mq smq)

  def setup
    super
    @data_block_size = k(32)
    @cache_blocks = 1024
  end

  #--------------------------------

  # We don't request format in these tests because the metadata is
  # going to be generated by cache_xml.
  def clean_data_never_gets_written_back(policy)
    s = CacheStack.new(@dm, @metadata_dev, @data_dev,
                       :policy => Policy.new(policy, :migration_threshold => 1024),
                       :format => false,
                       :cache_blocks => gig(1),
                       :block_size => k(64))
    s.activate_support_devs do
      s.prepare_populated_cache()

      traces, _ = blktrace(s.origin) do
        s.activate_top_level do
          sleep 15
        end
      end

      assert_equal([], filter_writes(traces[0]))
    end
  end

  define_tests_across(:clean_data_never_gets_written_back, POLICY_NAMES)

  #--------------------------------

  def dirty_data_always_gets_written_back(policy)
    cache_size = gig(1)
    block_size = k(64)

    s = CacheStack.new(@dm, @metadata_dev, @data_dev,
                       :policy => Policy.new(policy, :migration_threshold => 1024),
                       :format => false,
                       :cache_size => cache_size,
                       :block_size => block_size)
    s.activate_support_devs do
      s.prepare_populated_cache(:dirty_percentage => 100)
      traces, _ = blktrace(s.origin) do
        s.activate_top_level do
          # Writeback needs to be done in a timely manner
          Timeout::timeout(180) do
            wait_for_all_clean(s.cache)
          end
        end
      end

      assert_equal(cache_size / block_size, filter_writes(traces[0]).size)
    end
  end

  define_tests_across(:dirty_data_always_gets_written_back, POLICY_NAMES)

  #--------------------------------

  def cache_remains_clean_through_reload(policy)
    cache_size = gig(1)
    block_size = k(64)

    s = CacheStack.new(@dm, @metadata_dev, @data_dev,
                       :policy => Policy.new(policy, :migration_threshold => 1024),
                       :format => false,
                       :cache_size => cache_size,
                       :block_size => block_size)
    s.activate_support_devs do
      s.prepare_populated_cache(:dirty_percentage => 100)
      s.activate_top_level do
        # Writeback needs to be done in a timely manner
        Timeout::timeout(180) do
          wait_for_all_clean(s.cache)
        end
      end

      traces, _ = blktrace(s.origin) do
        s.activate_top_level do
          Timeout::timeout(180) do
            wait_for_all_clean(s.cache)
          end
        end
      end

      assert_equal([], filter_writes(traces[0]))
    end    
  end

  define_tests_across(:cache_remains_clean_through_reload, POLICY_NAMES)

  #--------------------------------

  private
  def filter_writes(events)
    events.select {|e| e.code.member?(:write)}
  end
end

#----------------------------------------------------------------
