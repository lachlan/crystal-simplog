require "./spec_helper"

describe SimpLog::FileBackend do
  it "calculates next rotation at midnight for rotations >= 1 day" do
    backend = SimpLog::FileBackend.new
    backend.next_rotation_at.should eq((Time.local + 1.day).at_beginning_of_day)
  end

  it "calculates next rotation using current time for rotations < 1 day" do
    backend = SimpLog::FileBackend.new
    backend.rotate_at = 5.minutes
    backend.next_rotation_at.at_beginning_of_minute.should eq((Time.local + 5.minutes).at_beginning_of_minute)
  end
end
