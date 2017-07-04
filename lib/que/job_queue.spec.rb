# frozen_string_literal: true

require 'spec_helper'

describe Que::JobQueue do
  let(:now) { Time.now }
  let(:old) { now - 50 }

  let :job_queue do
    Que::JobQueue.new(maximum_size: 8)
  end

  let :job_array do
    [
      {priority: 1, run_at: old, id: 1},
      {priority: 1, run_at: old, id: 2},
      {priority: 1, run_at: now, id: 3},
      {priority: 1, run_at: now, id: 4},
      {priority: 2, run_at: old, id: 5},
      {priority: 2, run_at: old, id: 6},
      {priority: 2, run_at: now, id: 7},
      {priority: 2, run_at: now, id: 8},
    ]
  end

  describe "#push" do
    it "should add an item and retain the sort order" do
      ids = []

      job_array.shuffle.each do |job|
        assert_nil job_queue.push(job)
        ids << job[:id]
        assert_equal ids.sort, job_queue.to_a.map{|j| j[:id]}
      end

      assert_equal job_array, job_queue.to_a
    end

    it "should be able to add many items at once" do
      assert_nil job_queue.push(*job_array.shuffle)
      assert_equal job_array, job_queue.to_a
    end

    describe "when the maximum size has been reached" do
      let :important_values do
        (1..3).map { |id| {priority: 0, run_at: old, id: id} }
      end

      before do
        job_queue.push(*job_array)
      end

      it "should pop the least important jobs and return their pks" do
        assert_equal \
          job_array[7..7].map{|j| j[:id]},
          job_queue.push(important_values[0])

        assert_equal \
          job_array[5..6].map{|j| j[:id]},
          job_queue.push(*important_values[1..2]).sort

        assert_equal 8, job_queue.size
      end

      it "should work when passing multiple pks that would pass the maximum" do
        assert_equal \
          job_array.first[:id],
          job_queue.shift

        assert_equal \
          job_array[7..7].map{|j| j[:id]},
          job_queue.push(*important_values[0..1])

        assert_equal 8, job_queue.size
      end

      # Pushing very low priority jobs shouldn't happen, since we use
      # #accept? to prevent unnecessary locking, but just in case:
      it "should work when the jobs wouldn't make the cut" do
        v = {priority: 100, run_at: Time.now, id: 45}
        assert_equal [45], job_queue.push(v)
        refute_includes job_queue.to_a, v
        assert_equal 8, job_queue.size
      end
    end
  end

  describe "#accept?" do
    before do
      job_queue.push *job_array
    end

    it "should return true if there is sufficient room in the queue" do
      assert_equal job_array.first[:id], job_queue.shift
      assert_equal 7, job_queue.size
      assert job_queue.accept?(job_array.last)
    end

    it "should return true if the job can knock out a lower-priority job" do
      assert job_queue.accept?(job_array.first)
    end

    it "should return false if the job's priority is lower than any queued" do
      refute job_queue.accept?({priority: 100, run_at: Time.now, id: 45})
    end
  end

  describe "#shift" do
    it "should return the lowest item's id by sort order" do
      job_queue.push *job_array

      assert_equal job_array[0][:id], job_queue.shift
      assert_equal job_array[1..7],   job_queue.to_a

      assert_equal job_array[1][:id], job_queue.shift
      assert_equal job_array[2..7],   job_queue.to_a
    end

    it "should block for multiple threads when the queue is empty" do
      job_queue # Pre-initialize to avoid race conditions.

      threads =
        4.times.map do
          Thread.new do
            Thread.current[:job] = job_queue.shift
          end
        end

      sleep_until { threads.all? { |t| t.status == 'sleep' } }
      job_queue.push *job_array
      sleep_until { threads.all? { |t| t.status == false } }

      assert_equal \
        job_array[0..3].map{|j| j[:id]},
        threads.map{|t| t[:job]}.sort

      assert_equal job_array[4..7], job_queue.to_a
    end

    it "should respect a minimum priority argument" do
      a = {priority: 10, run_at: Time.now, id: 1}
      b = {priority: 10, run_at: Time.now, id: 2}
      c = {priority:  5, run_at: Time.now, id: 3}

      job_queue.push(a)
      t = Thread.new { Thread.current[:job] = job_queue.shift(5) }
      sleep_until { t.status == 'sleep' }

      job_queue.push(b)
      sleep_until { t.status == 'sleep' }

      job_queue.push(c)
      sleep_until { t.status == false }

      assert_equal 3, t[:job]
    end

    it "when blocked should only return for a request of sufficient priority" do
      job_queue # Pre-initialize to avoid race conditions.

      # Randomize order in which threads lock.
      threads = [5, 10, 15, 20].shuffle.map do |priority|
        Thread.new do
          Thread.current[:priority] = priority
          Thread.current[:job] = job_queue.shift(priority)
        end
      end

      sleep_until { threads.all? { |t| t.status == 'sleep' } }

      threads.sort_by! { |t| t[:priority] }

      value = {priority: 17, run_at: Time.now, id: 1}
      job_queue.push value

      sleep_until { threads[3].status == false }
      assert_equal 1, threads[3][:job]
      sleep_until { threads[0..2].all? { |t| t.status == 'sleep' } }
    end
  end

  describe "#stop" do
    it "should return nil to waiting workers" do
      job_queue # Pre-initialize to avoid race conditions.

      threads =
        4.times.map do
          Thread.new do
            Thread.current[:job] = job_queue.shift
          end
        end

      sleep_until { threads.all? { |t| t.status == 'sleep' } }
      job_queue.stop
      sleep_until { threads.all? { |t| t.status == false } }

      threads.map { |t| assert_nil t[:job] }
      10.times { assert_nil job_queue.shift }
    end
  end

  describe "#clear" do
    it "should remove and return all items" do
      job_queue.push *job_array
      assert_equal job_array.map{|job| job[:id]}, job_queue.clear.sort
      assert_equal [], job_queue.to_a
    end

    it "should return an empty array if there are no items to clear" do
      assert_equal [], job_queue.clear
      job_queue.push *job_array
      assert_equal job_array.map{|job| job[:id]}, job_queue.clear.sort
      assert_equal [], job_queue.clear
    end
  end
end