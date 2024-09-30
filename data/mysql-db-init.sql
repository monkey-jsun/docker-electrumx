drop database if exists `electrumx_transactions`;

drop user if exists 'ex_admin'@'%';
drop user if exists 'ex_writer'@'%';
drop user if exists 'ex_reader'@'%';

create database `electrumx_transactions` CHARACTER SET utf8 COLLATE utf8_general_ci;

create user 'ex_admin'@'%' identified by 'CHANGE_ME_FOR_ADMIN_PASSWORD';
grant SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,ALTER on electrumx_transactions.* to 'ex_admin'@'%';
create user 'ex_writer'@'%' identified by 'CHANGE_ME_FOR_WRITER_PASSWORD';
grant SELECT,INSERT,UPDATE,DELETE, LOCK TABLES on electrumx_transactions.* to 'ex_writer'@'%';
create user 'ex_reader'@'%' identified by 'CHANGE_ME_FOR_READER_PASSWORD';
grant SELECT on electrumx_transactions.* to 'ex_reader'@'%';

use `electrumx_transactions`;

create table if not exists `transaction` (
	`id` int(11) NOT NULL AUTO_INCREMENT,
	`received_time` TIMESTAMP not null,
	`tx_id` char(64) not null,
	`size` INT not null,
	`vsize` INT not null,
	`vin_count` INT not null,
	`vout_count` INT not null,
	`value` DECIMAL(16,8) not null,
	`ip_addr` VARCHAR(31),
	`port` INT,

	PRIMARY KEY (`id`)
) ENGINE=INNODB AUTO_INCREMENT=1 ;


