require 'digest'
require 'dmtest/fs'
require 'dmtest/utils'
require 'dmtest/dataset'
require 'dmtest/disk-units'
require 'dmtest/thinp-test'
require 'dmtest/clone_stack'
require 'dmtest/clone_utils'
require 'dmtest/pattern_stomper'

require 'rspec/expectations'

#----------------------------------------------------------------

class ConsistencyTests < ThinpTestCase
  include Utils
  include DiskUnits
  include CloneUtils
  extend TestUtils

  FSTYPES = [:xfs, :ext4]

  def setup
    super

    @region_size = k(4)
    @size = gig(10)
    @metadata_size = meg(16)
    @test_file_size = gig(1)

    check_dev_size(@metadata_dev, @data_dev, @size, @metadata_size)
  end

  def mkfs(dev, fs_type)
    puts "Formatting..."
    fs = FS::file_system(fs_type, dev)
    fs.format
  end

  def with_fs(dev, fs_type)
    fs = FS::file_system(fs_type, dev)

    fs.with_mount('./bench_mnt') do
      Dir.chdir('./bench_mnt') do
        yield fs
      end
    end
  end

  def md5sum(path)
    chunk_size = 1 << 20  # 1 MiB
    md5 = Digest::MD5.new

    File.open(path, "rb") do |f|
      until f.eof?
        md5 << f.read(chunk_size)
      end
    end

    md5.hexdigest
  end

  define_test :pattern_stomp_test do
    size = gig(1)
    s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => size,
                       :metadata_size => @metadata_size,
                       :region_size => @region_size, :hydration => false)

    s.activate_support_devs do
      source_stomper = PatternStomper.new(s.source.path, @region_size)
      source_stomper.stamp(20)

      s.activate_top_level do
        clone_stomper = source_stomper.fork(s.clone.path)
        clone_stomper.verify(0, 1)

        clone_stomper.stamp(10)
        clone_stomper.verify(0, 2)
        source_stomper.verify(0, 1)

        s.enable_hydration
        s.wait_until_hydrated

        clone_stomper.verify(0, 2)
        source_stomper.verify(0, 1)

        clone_stomper.stamp(5)
        clone_stomper.verify(0, 3)
        source_stomper.verify(0, 1)
      end
    end
  end

  def filesystem_test(fs_type)
    s = CloneStack.new(@dm, @metadata_dev, @data_dev, :size => @size,
                       :metadata_size => @metadata_size,
                       :region_size => @region_size, :hydration => false)

    test_file_md5sum = nil

    s.activate_support_devs do
      mkfs(s.source, fs_type)

      with_fs(s.source, fs_type) do
        # Populate FS
        ds = Dataset.read(LP('compile-bench-datasets/dataset-unpatched'))

        Dir.mkdir('linux')
        Dir.chdir('linux') do
          ds.apply
        end

        # Fill test file with random data
        io_size = meg(1)
        ProcessControl.run("dd if=/dev/urandom of=testfile bs=#{io_size * 512} count=#{@test_file_size / io_size}")

        test_file_md5sum = md5sum("./testfile")
      end

      s.activate_top_level do
        with_fs(s.clone, fs_type) do |fs|
          # Check that file is read correctly through the dm-clone device
          expect(md5sum("./testfile")).to eq(test_file_md5sum)
          ProcessControl.run("echo 3 > /proc/sys/vm/drop_caches")

          # Check that fstrim doesn't corrupt the file
          fs.trim

          expect(md5sum("./testfile")).to eq(test_file_md5sum)
          ProcessControl.run("echo 3 > /proc/sys/vm/drop_caches")

          # Check that hydration doesn't corrupt the file
          s.enable_hydration
          s.wait_until_hydrated

          expect(md5sum("./testfile")).to eq(test_file_md5sum)
        end
      end
    end
  end

  define_tests_across(:filesystem_test, FSTYPES)
end
#----------------------------------------------------------------
