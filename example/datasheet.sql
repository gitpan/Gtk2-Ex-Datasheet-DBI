-- MySQL dump 10.10
--
-- Host: localhost    Database: datasheet
-- ------------------------------------------------------
-- Server version	5.0.4-beta-log

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8 */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `BirdsOfAFeather`
--

DROP TABLE IF EXISTS `BirdsOfAFeather`;
CREATE TABLE `BirdsOfAFeather` (
  `ID` smallint(5) unsigned NOT NULL auto_increment,
  `FirstName` varchar(20) default NULL,
  `LastName` varchar(20) default NULL,
  `Active` tinyint(1) default '0',
  `GroupNo` tinyint(3) unsigned NOT NULL,
  PRIMARY KEY  (`ID`),
  KEY `IDX_GroupNo` (`GroupNo`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

--
-- Dumping data for table `BirdsOfAFeather`
--


/*!40000 ALTER TABLE `BirdsOfAFeather` DISABLE KEYS */;
LOCK TABLES `BirdsOfAFeather` WRITE;
INSERT INTO `BirdsOfAFeather` VALUES (14,'George W','Bush',1,1),(13,'Arial','Sharon',1,2),(12,'Adolf','Hitler',0,3),(11,'Saddam','Hussein',0,4);
UNLOCK TABLES;
/*!40000 ALTER TABLE `BirdsOfAFeather` ENABLE KEYS */;

--
-- Table structure for table `Groups`
--

DROP TABLE IF EXISTS `Groups`;
CREATE TABLE `Groups` (
  `ID` tinyint(4) NOT NULL auto_increment,
  `Description` varchar(30) NOT NULL,
  PRIMARY KEY  (`ID`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

--
-- Dumping data for table `Groups`
--


/*!40000 ALTER TABLE `Groups` DISABLE KEYS */;
LOCK TABLES `Groups` WRITE;
INSERT INTO `Groups` VALUES (1,'US Government'),(2,'Israeli Government'),(3,'Nazi Party'),(4,'Baath Party');
UNLOCK TABLES;
/*!40000 ALTER TABLE `Groups` ENABLE KEYS */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

