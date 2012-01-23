Introduction
============

This is a quick hack that allows you to access the Graylog2 data that is
stored in a local ElasticSearch instance via a gem, so that you can
regularly archive statistics of your streams and so on.

We use this at Spaceship for exactly that.

We basically wrapped part of Graylog2's model classes (MessageGateway and some
dependencies) in a module. Credits for this code belongs to Lennart
Koopmann et al.

Usage Example
=============

    require "graylog2"
    
    total_logins = Graylog2::MessageGateway.all_by_quickfilter({
      :message=>'"login successful"'
    },1).total_result_count

