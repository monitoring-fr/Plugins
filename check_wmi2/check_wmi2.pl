#!/usr/bin/perl -w
################################################################################
# Copyright (C) 2010 Olivier LI-KIANG-CHEONG
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program; if not, see http://www.gnu.org/licenses
# or write to the Free Software Foundation,Inc., 51 Franklin Street,
# Fifth Floor, Boston, MA 02110-1301  USA
#
################################################################################
# Version : 1.0
################################################################################
# Author : Olivier LI-KIANG-CHEONG <lkco@gezen.fr>
################################################################################
# CHANGELOG :
# 1.0 : initial release
################################################################################

use strict;

use strict;
use Getopt::Long;
use Switch;
use File::Basename;
use Data::Dumper;
use vars qw($PROGNAME);

#### Options Definitions ###
my ($opt_V, $opt_v, $opt_h, $opt_m, $opt_H, $opt_u, $opt_p, $opt_a, $opt_w, $opt_c, $opt_t, $opt_U, $opt_P, $opt_T);
my ($cmd, $output, @results, @arguments, $message, $age, $size, $st);

# Default value
$opt_a = "";
$opt_T = "Linux";

Getopt::Long::Configure('bundling');
GetOptions(
    "h"   => \$opt_h, "help"        => \$opt_h,
    "m=s" => \$opt_m, "mode"        => \$opt_m,
    "H=s" => \$opt_H, "hostname"    => \$opt_H,
    "u=s" => \$opt_u, "username"    => \$opt_u,
    "p=s" => \$opt_p, "password"    => \$opt_p,
    "a=s" => \$opt_a, "argument"    => \$opt_a,
    "w=s" => \$opt_w, "warning=s"   => \$opt_w,
    "c=s" => \$opt_c, "critical=s"  => \$opt_c,
    "T=s" => \$opt_T, "type"        => \$opt_T,
    "t=i" => \$opt_t, "timeout"     => \$opt_t,                                                                                                          
    "v"   => \$opt_v, "verbose"     => \$opt_v,
);


#### END Options Definitions ###

### GLOBAL VARIABLES ###
my $PROGNAME = basename($0);
my %ERRORS=(
    'OK'        => 0,
    'WARNING'   => 1,
    'CRITICAL'  => 2,
    'UNKNOWN'   => 3,
    'DEPENDENT' => 4
);

my $LINUX_WMIC_BIN = "/bin/wmic";
my $WINDOWS_WMIC_BIN = "wmic.exe";
my %QUERY_LISTDISK = (
   "table"        => "Win32_LogicalDisk",
   "attribut"     => ["DeviceID","Description"],
   "where_clause" => "",
);

my %QUERY_CHECKDISKSIZE = (
   "table"        => "Win32_LogicalDisk",
   "attribut"     => ["size","freespace"],
   "where_clause" => "DeviceID='".$opt_a."'",
);

my %QUERY_CHECKCPULOAD = (
   "table"        => "Win32_PerfFormattedData_PerfOS_Processor",
   "attribut"     => ["PercentProcessorTime","Name"],
   "where_clause" => "Name='_Total'",
);

my %QUERY_CHECKMEMORY = (
   "table"        => "Win32_OperatingSystem", 
   "attribut"     => ["FreePhysicalMemory","TotalVisibleMemorySize"],
   "where_clause" => ""
);

my %QUERY_CHECKSERVICESTATE = (
   "table"        => "Win32_Service",
   "attribut"     => ["state"],
   "where_clause" => "Name='".$opt_a."'",
);

my %QUERY_LISTSERVICES = (
   "table"        => "Win32_Service",
   "attribut"     => ["State","Name","StartMode"],
   "where_clause" => ""
);


### END GLOBAL VARIABLES ###

#### Function Declaration ####
sub verb;
sub print_help ();
sub print_usage ();
sub check_options ();
sub run_cmd ();

sub verb {
    my $text = shift;
    print "== Debug == $text\n" if ($opt_v);
}

sub print_help () {
    print_usage();
    print "The plugin check                                                             .\n";
    print "With -m option, it can check                                     .\n\n";
    print "   -H (--hostname)       Hostname to query - (required)\n";
    print "   -u (--username)       Username\n";
    print "   -p (--password)       The password\n";
    print "   -w (--warning)        Signal strength at which a warning message will be generated\n";
    print "   -c (--critical)       Signal strength at which a critical message will be generated\n";
    print "   -h (--help)           Print help\n";
    print "   -v (--verbose)        Print extra verbing information\n";
    print "   -T (--type)           Use Windows to use wmic.exe or Linux to use vmic (Default: Linux)\n";
    print "   -m listdisk           List the disk available \n";
    print "      $PROGNAME -u <login> -p <password> -H XX.XX.XX.XX -m listdisk -T Linux\n";
    print "   -m checkdisksize       \n";
    print "      $PROGNAME -u <login> -p <password> -H XX.XX.XX.XX -m checkdisksize -a 'C:' -w 90 -c 95 -T Linux\n";
    print "   -m checkcpuload        \n";
    print "      $PROGNAME -u <login> -p <password> -H XX.XX.XX.XX -m checkcpuload -w 90 -c 95 -T Linux\n";
    print "   -m checkphysicalmemory            \n";
    print "      $PROGNAME -u <login> -p <password> -H XX.XX.XX.XX -m checkphysicalmemory -w 90 -c 95 -T Linux\n";
    print "   -m listservices        \n";
    print "      $PROGNAME -u <login> -p <password> -H XX.XX.XX.XX -m listservices -T Linux\n";
    print "   -m checkservice        \n";
    print "      $PROGNAME -u <login> -p <password> -H XX.XX.XX.XX -m checkservice -a 'TermService -T Linux\n";
    print "   -m checkeventlog       \n"; ## TODO
    print "\n";
}

sub print_usage () {
    print "Usage: $PROGNAME -H <hostname> u <username> -p <password> -T [Linux|Windows] -m [checkdisksize|checkcpuload|checkphysicalmemory|checkeventlog|checkservice|checkwsusserver|listdisk] -w <warning> -c <critical> \n";
    print "       $PROGNAME --help : To print help\n";
}

sub check_options () {
    if ($opt_h) {
            print_help();
            exit $ERRORS{'OK'};
    }

    if (!$opt_m) {
            print "No mode specified\n\n";
            print_usage();
            exit $ERRORS{'UNKNOWN'};
    }

    if (!$opt_H) {
            print "No Hostname specified\n\n";
            print_usage();
            exit $ERRORS{'UNKNOWN'};
    }
 
    if (($opt_T ne "Linux") && ($opt_T ne "Windows")) {
            print "No Type valid (use -T Linux or -T Windows)\n\n";
            print_usage();
            exit $ERRORS{'UNKNOWN'};
    }

    if (($opt_m eq "checkservice") && ($opt_a eq "") ) {
            print "Missing parameter\n\n";
            print_usage();
            exit $ERRORS{'UNKNOWN'};
    }
 
    if (($opt_m eq "checkcpuload") || ($opt_m eq "checkphysicalmemory") ) {
        if (!$opt_c) { 
	    print "No critical threshold specified\n\n";
            print_usage();
            exit $ERRORS{'UNKNOWN'};
        } elsif (!$opt_w) { 
            print "No warning threshold specified\n\n";
            print_usage();
            exit $ERRORS{'UNKNOWN'};
        }
    }

    if ($opt_m eq "checkdisksize") {
        if (!$opt_c) { 
	    print "No critical threshold specified\n\n";
            print_usage();
            exit $ERRORS{'UNKNOWN'};
        } elsif (!$opt_w) { 
            print "No warning threshold specified\n\n";
            print_usage();
            exit $ERRORS{'UNKNOWN'};
        } elsif (!$opt_a) {
            print "Missing parameter\n\n";
            print_usage();
            exit $ERRORS{'UNKNOWN'};
        }
    }

}

# Syntax : run_cmd(%hash) and return hash result
# Example : run_cmd(%QUERY_CHECKDISKSIZE)
# Return an array :
#    [
#      {
#        'DeviceID' => 'C:',
#        'Size' => '73509412864',
#        'FreeSpace' => '3480375296'
#      }
#    ];

sub run_cmd () {
    my (%requete) = @_; 
    if ($opt_T eq "Linux") {
        # Run the query with LINUX_WMIC_BIN
        my @response;
        verb("Type Linux");

        my $sql = "SELECT ".join(",",@{$requete{"attribut"}})." FROM ".$requete{"table"};
        $sql .= " WHERE ".$requete{"where_clause"} if (defined($requete{"where_clause"}) && $requete{"where_clause"} ne "");
        verb("SQL Query: $sql");
        
        # Run cmd
        $cmd = "$LINUX_WMIC_BIN -U ".$opt_u ."%".$opt_p." //".$opt_H." \"$sql\"";
        verb("COMMAND : $cmd");
        my @output = `$cmd`;
        map(chomp, @output);
        if ($output[0] !~ m/CLASS: $requete{"table"}/) {
            return @response;
        } else{
            shift @output
        }

        # Return results
        my @header = split(/\|/, shift @output);
        # Parse the result
        foreach my $ligne (@output) {
           my @results = split(/\|/, $ligne);
           my $i = 0;
           my %row;
           # Compose attribut => result
           foreach my $dec (@header) {
               $row{$dec} = $results[$i];
              $i++;
           }
           push(@response,\%row);
        }
        print Dumper \@response if ($opt_v);
        return @response;

    } elsif ($opt_T eq "Windows") {
        verb("Type Windows");

    }
}

### END Function Declaration ###

### MAIN ###

check_options();

switch ($opt_m) {
    case "listdisk" {
        my @row = &run_cmd(%QUERY_LISTDISK);
        if (scalar(@row) == 0) {
            print "UNKNOWN: No disk found\n";
            exit $ERRORS{'UNKNOWN'};
        }
       
        verb("List Disk");
        print Dumper \@row if ($opt_v);
        print "    List Disk found \n";

        foreach (@row) {                                                                                                                    
            my %r = %{$_};
            foreach my $k (keys %r) {
                printf("%-15s %-10s\n",$k,$r{$k});
            }
            print "\n";
        }

    }

    case "checkdisksize" {
        my @row = &run_cmd(%QUERY_CHECKDISKSIZE);

        if (scalar(@row) == 0) {
            print "UNKNOWN: No disk $opt_a found";
            exit $ERRORS{'UNKNOWN'};
        } elsif (scalar(@row) > 1) {
            print "UNKNOWN: Find more than one result\n";
            exit $ERRORS{'UNKNOWN'};
        }
       
        verb("Check Disk size : $opt_a");
        print Dumper \@row if ($opt_v);

        my %results = %{$row[0]};
        my $free = $results{"FreeSpace"};
        my $size = $results{"Size"};
        if ($size == 0) {
            print "Can't retrieve the disk size";
            exit $ERRORS{'UNKNOWN'};
        }
        my $disk_usage_percent = sprintf("%.f",($size-$free)*100/$size);
        verb("$opt_a size : $size B");
        verb("$opt_a free : $free B");
        verb("$opt_a disk_usage_percent : $disk_usage_percent%");
        my $exit_code = $ERRORS{'OK'};
        my $msg = "";

        if ($disk_usage_percent >= $opt_c) {
            verb("Disk CRITICAL");
            $msg .= "Disk CRITICAL ";
            $exit_code = $ERRORS{'CRITICAL'};
        } elsif ($disk_usage_percent >= $opt_w) {
            verb("Disk WARNING");
            $msg .= "Disk WARNING ";
            $exit_code = $ERRORS{'WARNING'};
        } else {
            $msg .= "Disk OK ";
        }

        my $totalGB = sprintf("%.3f",$size/1073741824);
        my $used = $size-$free;
        my $usedGB = sprintf("%.3f",$used/1073741824);
        my $freeGB = sprintf("%.3f",$free/1073741824);
        my $warn = sprintf("%.0f",$size*$opt_w/100);
        my $crit = sprintf("%.0f",$size*$opt_c/100);

        $msg .= "- $opt_a TOTAL: ".$totalGB."GB USED: ".$usedGB."GB (".$disk_usage_percent."%) FREE: ".$freeGB."GB (".(100-$disk_usage_percent)."%)";
        $msg .= " |size=".$size."B used=".$used."B,$warn,$crit,0,$size";
        print "$msg\n";
        exit $exit_code;
    }

    case "checkcpuload" {
        my @row = &run_cmd(%QUERY_CHECKCPULOAD);
        verb("Check CPU load");
        print Dumper \@row if ($opt_v);

        if (scalar(@row) == 0) {
            print "UNKNOWN: No information found for CPU load\n";
            exit $ERRORS{'UNKNOWN'};
        } elsif (scalar(@row) > 1) {
            print "UNKNOWN: Find more than one result\n";
            exit $ERRORS{'UNKNOWN'};
        }

        my %results = %{$row[0]};
        my $load = $results{"PercentProcessorTime"};
        
        my $msg = "";
        my $exit_code = $ERRORS{'OK'};

        if ($load >= $opt_c) {
            $exit_code = $ERRORS{'CRITICAL'};
            $msg .= "CPU Load CRITICAL";
        } elsif ($load >= $opt_w) {
            $exit_code = $ERRORS{'WARNING'};
            $msg .= "CPU Load WARNING";
        }else{  
            $msg .= "CPU Load OK";
        }
        $msg .= " - utilization ".$load."%|current_load=$load%,$opt_w,$opt_c,0,100";
        print "$msg\n";
        exit $exit_code;
    }

    case "checkphysicalmemory" {
        my @row = &run_cmd(%QUERY_CHECKMEMORY);
        verb("Check Memory");
        print Dumper \@row if ($opt_v);

        if (scalar(@row) == 0) {
            print "UNKNOWN: No information found for Physical memory\n";
            exit $ERRORS{'UNKNOWN'};
        } 

        my %results = %{$row[0]};
        my $free = $results{"FreePhysicalMemory"};
        my $size = $results{"TotalVisibleMemorySize"};
        if ($size == 0) {
            print "Can't retrieve the disk size";
            exit $ERRORS{'UNKNOWN'};
        }

        my $mem_usage_percent = sprintf("%.f",($size-$free)*100/$size);
        verb("Physical Memory size : $size KB");
        verb("Physical Memory free : $free KB");
        verb("Physical Memory mem_usage_percent : $mem_usage_percent%");
        my $exit_code = $ERRORS{'OK'};
        my $msg = "";

        if ($mem_usage_percent >= $opt_c) {
            verb("Physical Memory CRITICAL");
            $msg .= "Memory CRITICAL ";
            $exit_code = $ERRORS{'CRITICAL'};
        } elsif ($mem_usage_percent >= $opt_w) {
            verb("Physical Memory WARNING");
            $msg .= "Memory WARNING ";
            $exit_code = $ERRORS{'WARNING'};
        } else {
            $msg .= "Physical Memory OK ";
        }

        my $totalGB = sprintf("%.3f",$size/1048576);
        my $used = $size-$free;
        my $usedGB = sprintf("%.3f",$used/1048576);
        my $freeGB = sprintf("%.3f",$free/1048576);
        my $warn = sprintf("%.0f",$size*$opt_w/100);
        my $crit = sprintf("%.0f",$size*$opt_c/100);

        $msg .= "- Physical Memory TOTAL: ".$totalGB."GB USED: ".$usedGB."GB (".$mem_usage_percent."%) FREE: ".$freeGB."GB (".(100-$mem_usage_percent)."%)";
        $msg .= " |size=".$size."B used=".$used."B,$warn,$crit,0,$size";
        print "$msg\n";
        exit $exit_code;
    }

    case "listservices" {
        my @row = &run_cmd(%QUERY_LISTSERVICES);
        verb("List all Services");
        print Dumper \@row if ($opt_v);

        if (scalar(@row) == 0) {
            print "UNKNOWN: No information found for all Services\n";
            exit $ERRORS{'UNKNOWN'};
        }

        print "    List Services found \n";
            printf("%-30s %-10s %-10s\n","NAME","STATE","STARTMODE");
        foreach (@row) {
            my %r = %{$_};
            printf("%-30s %-10s %-10s\n",$r{"Name"},$r{"State"},$r{"StartMode"} );
        }

    }

    case "checkservice" {
        my @row = &run_cmd(%QUERY_CHECKSERVICESTATE);
        verb("Check Services $opt_a");
        print Dumper \@row if ($opt_v);

        if (scalar(@row) == 0) {
            print "UNKNOWN: No information found for Physical memory\n";
            exit $ERRORS{'UNKNOWN'};
        }

        my %results = %{$row[0]};
        my $state = $results{"State"};
        verb("Service '$opt_a' : $state");

        my $exit_code = $ERRORS{'OK'};
        my $msg = "";

        if ($state =~ /Stopped/) {
            $exit_code = $ERRORS{'CRITICAL'};
            $msg .= "Service '$opt_a' CRITICAL : $state";
        }elsif ($state =~ /Running/) {
            $msg .= "Service '$opt_a' OK : $state";
        }else {
            $exit_code = $ERRORS{'UNKNOWN'};
            $msg .= "Service '$opt_a' UNKNOWN : $state";
        }

        print "$msg\n";
        exit $exit_code;
    }
}

### END MAIN ###
