require "./spec_helper"
require "log"

describe SimpLog::FileBackend do
  it "calculates next rotation at midnight for rotations >= 1 day" do
    backend = SimpLog::FileBackend.new(File.tempname + ".log")
    backend.next_rotation_at.should eq((Time.local + 1.day).at_beginning_of_day)
  end

  it "calculates next rotation using current time for rotations < 1 day" do
    backend = SimpLog::FileBackend.new(File.tempname + ".log")
    backend.rotate_at = 5.minutes
    backend.next_rotation_at.at_beginning_of_minute.should eq((Time.local + 5.minutes).at_beginning_of_minute)
  end

  it "logs to file" do
    backend = SimpLog::FileBackend.new(File.tempname + ".log", dispatcher: Log::DispatchMode::Direct)
    backend.rotate_at = 5.minutes
    Log.setup_from_env(backend: backend)
    message = "#{Time.local.to_s} logs to file test message"
    Log.info { message }
    content = File.read(backend.filename)
    content.should contain("INFO - #{message}")
  end
end
