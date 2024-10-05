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
limit 1;"

hours=6
total_sleep=$((60 * 60 * $hours))    # 6 hours
echo $total_sleep

output=$(echo $sql | mysql --user=ex_reader --password=$EX_READER_PASS electrumx_transactions)
echo $output

while true; do
    sleep $total_sleep
    new_output=$(echo $sql | mysql --user=ex_reader --password=$EX_READER_PASS electrumx_transactions)
    echo $new_output
    if [[ "$output" == "$new_output" ]]; then
        echo $hours hours new new record.  This is a problem!
        wget -qO- --post-data "msg=Electrumx has no new tx in last $hours hours!!" http://junsun.net/misc/emailme.php
    fi
    output=$new_output
done

