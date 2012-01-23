
require "rubygems"
require "graylog2"

r=Graylog2::MessageGateway.all_by_quickfilter({:message=>'"login successful"'},1).total_result_count
puts r
