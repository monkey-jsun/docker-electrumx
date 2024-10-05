sql="
select 
	year(received_time) as year, 
	month(received_time) as month, 
	day(received_time) as day, 
	count(*) as count, 
	sum(value) as value 
from transaction 
group by year(received_time),month(received_time),day(received_time) 
order by year(received_time) DESC,month(received_time) DESC,day(received_time) DESC 
limit 24;"

echo $sql | mariadb --user=ex_reader --password=$EX_READER_PASS electrumx_transactions

echo
date
