# Copyright (c) 2009-2011 VMware, Inc.
require "mysql"

module VCAP; module Services; module Mysql; end; end; end

class VCAP::Services::Mysql::Node

  DATA_LENGTH_FIELD = 6

  def db_size(db)
    # calculate both index and table size
    dbs = @connection.query("SELECT sum( data_length + index_length) 'size'
                              FROM information_schema.TABLES
                              WHERE table_schema = '#{db}'
                              GROUP BY table_schema ;")
    res = 0
    dbs.each {|i| res+=i[0].to_i}
    res
  end

  def dbs_size()
    result = @connection.query('show databases')
    dbs =[]
    result.each {|db| dbs << db[0]}
    sizes = @connection.query(
      'SELECT table_schema "name",
       sum( data_length + index_length ) "size"
       FROM information_schema.TABLES
       GROUP BY table_schema')
    result ={}
    sizes.each do |i|
      name, size = i
      result[name] = size.to_i
    end
    # assume 0 size for db which has no tables
    dbs.each {|db| result[db] = 0 unless result.has_key? db}
    result
  end

  def kill_user_sessions(target_user, target_db)
    process_list = @connection.list_processes
    process_list.each do |proc|
      thread_id, user, _, db = proc
      if (user == target_user) and (db == target_db) then
        @connection.query('KILL CONNECTION ' + thread_id)
      end
      end
  end

  def access_disabled?(db)
    rights = @connection.query("SELECT insert_priv, create_priv, update_priv
                                FROM db WHERE Db=" +  "'#{db}'")
    rights.each do |right|
      if right.include? 'Y' then
        return false
      end
    end
    true
  end

  def grant_write_access(db, service)
    @logger.warn("DB permissions inconsistent....") unless access_disabled?(db)
    @connection.query("UPDATE db SET insert_priv='Y', create_priv='Y',
                       update_priv='Y' WHERE Db=" +  "'#{db}'")
    @connection.query("FLUSH PRIVILEGES")
    service.quota_exceeded = false
    service.save
  end

  def revoke_write_access(db, service)
    user = service.user
    @logger.warn("DB permissions inconsistent....") if access_disabled?(db)
    @connection.query("UPDATE db SET insert_priv='N', create_priv='N',
                       update_priv='N' WHERE Db=" +  "'#{db}'")
    @connection.query("FLUSH PRIVILEGES")
    kill_user_sessions(user, db)
    service.quota_exceeded = true
    service.save
  end

  def fmt_db_listing(user, db, size)
    "<user: '#{user}' name: '#{db}' size: #{size}>"
  end

  def enforce_storage_quota
    @connection.select_db('mysql')
    ProvisionedService.all.each do |service|
      db, user, quota_exceeded = service.name, service.user, service.quota_exceeded
      size = db_size(db)

      if (size >= @max_db_size) and not quota_exceeded then
        revoke_write_access(db, service)
        @logger.info("Storage quota exceeded :" + fmt_db_listing(user, db, size) +
                     " -- access revoked")
      elsif (size < @max_db_size) and quota_exceeded then
        grant_write_access(db, service)
        @logger.info("Below storage quota:" + fmt_db_listing(user, db, size) +
                     " -- access restored")
      end
    end
    rescue Mysql::Error => e
      @logger.warn("MySQL exception: [#{e.errno}] #{e.error}\n" +
                   e.backtrace.join("\n"))
  end

end
