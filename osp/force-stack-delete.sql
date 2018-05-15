# Script to force delete stuck overcloud deployments

delimiter //
drop procedure if exists hunt //
 
set @overcloud_id = (SELECT id FROM heat.stack where name = "overcloud");

create procedure hunt()
begin
  DECLARE done int default false;
  DECLARE thing CHAR(255);
  DECLARE cur1 cursor for SELECT TABLE_NAME FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = "heat" and COLUMN_NAME = "stack_id";
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
  open cur1;
 
  myloop: loop
    fetch cur1 into thing;
    if done then
      leave myloop;
    end if;
    set @sql = CONCAT('delete from `heat`.', thing, ' where stack_id = "', @overcloud_id, '"');
    select @sql as "Deleting row";
    prepare stmt from @sql;
    execute stmt;
    drop prepare stmt;
  end loop;
 
  close cur1;
end //
 
#delimeter ;
 
call hunt();

set @last_touch = CONCAT('UPDATE heat.stack SET action="DELETE", status="COMPLETE", current_deps=\'{"edges": [[[1, false], null]]}\', deleted_at="2017-03-17 12:22:01" where id = "', @overcloud_id, '"'); 
select @last_touch;
prepare stmt2 from @last_touch;
execute stmt2;
