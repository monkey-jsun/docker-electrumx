sql="
select 
	year(received_time) as year, 
	month(received_time) as month, 
	day(received_time) as day, 
	value,
    ip_addr,
    port,
    vin_count,
    vout_count
from transaction 
where value>10
order by year(received_time) DESC,month(received_time) DESC,day(received_time) DESC 
limit 24;"

echo $sql | mariadb --user=ex_reader --password=$EX_READER_PASS electrumx_transactions

echo
date
