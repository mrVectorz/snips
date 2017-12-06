/* This creates a db named "duck". Then creates a table with primary key
    named "example_id" which auto-increments and is a 10b int,
    and a field "name"*/
create database duck;
create table test (example_id int(10) auto_increment,
  name varcharr(100), primary key (example_id));
insert into test name values "valerie";
update set test name = "valerie-is-awesome" where name == "valerie";
drop table test;
drop database fuck;


/* simple user stuff */
create user test@'%' identified by 'passord';
grant select,insert,delete,update on database.table to 'test'@'%';
/* If you modify the grant tables directly using statements such as
    INSERT, UPDATE, or DELETE, your changes have no effect on privilege checking
    until you either restart the server or tell it to reload the tables.
    If you change the grant tables directly but forget to reload them,
    your changes have no effect until you restart the server.
    This may leave you wondering why your changes seem to make no difference! */
flush privileges;

/* Setting a var "@overcloud_id" and executing prepared statements,
    easy to do for var subs */
set @overcloud_id = (SELECT id FROM heat.stack where name = "overcloud");
set @last_touch = CONCAT('UPDATE heat.stack SET action="DELETE", 
  status="COMPLETE", current_deps=\'{"edges": [[[1, false], null]]}\', 
  deleted_at="2017-03-17 12:22:01" where id = "', @overcloud_id, '"'); 
prepare stmt2 from @last_touch;
execute stmt2;

