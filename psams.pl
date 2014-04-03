#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Std;
use Config::Tiny;
use DBI;
use String::Approx qw(adist);
use FindBin qw($Bin);
use HTML::Entities qw(decode_entities encode_entities);
use constant DEBUG => 1;

################################################################################
# Begin variables
################################################################################
#my (%opt, @accessions, $fasta, $species, $fb, $ids, $bg, @t_sites, $construct);
my (%opt, @accessions, $fasta, $species, $fb, $construct);
getopts('a:s:t:f:c:ho',\%opt);
arg_check();

# Constants
our $conf_file = "$Bin/../psams.conf";
our $targetfinder = "$Bin/targetfinder.pl";
our $conf = Config::Tiny->read($conf_file);
our $mRNAdb = $conf->{$species}->{'mRNA'};
our $db = $conf->{$species}->{'sql'};
our $seed = 15;
our $esc = '^\n\x20\x41-\x5a\x61-\x7a';

# Connect to the SQLite database
our $dbh = DBI->connect("dbi:SQLite:dbname=$db","","");

################################################################################
# End variables
################################################################################

################################################################################
# Begin main
################################################################################

if ($construct eq 'amiRNA') {
	# Get target sequences
	my $ids;
	my $bg = ($opt{'o'}) ? 1 : 0;
	if ($fasta) {
		$ids = build_fg_index_fasta($fasta);
	} else {
		$ids = build_fg_index(@accessions);
	}
	
	# Run pipeline
	pipeline($ids, $seed, $bg, $fb, $construct);
	
} elsif ($construct eq 'syntasiRNA') {
	
} else {
	arg_error("Construct type $construct is not supported!");
}

sub pipeline {
	my $ids = shift;
	my $seed = shift;
	my $bg = shift;
	my $fb = shift;
	my $construct = shift;
	
	# Find sites
	my @t_sites = get_tsites($ids, $seed, $bg);
	
	# Group sites
	my @gsites = group_tsites($seed, @t_sites);
	
	# Scoring sites
	my $target_count = scalar(keys(%{$ids}));
	@gsites = score_sites($target_count, $seed, @gsites);
	
	print STDERR "Sorting and outputing results... \n" if (DEBUG);
	@gsites = sort {
		$a->{'other_mm'} <=> $b->{'other_mm'}
			||
		$a->{'p21'} <=> $b->{'p21'}
			||
		$a->{'p3'} <=> $b->{'p3'}
			||
		$a->{'p2'} <=> $b->{'p2'}
			||
		$a->{'p1'} <=> $b->{'p1'}
	} @gsites;
	print STDERR "Analyzing ".scalar(@gsites)." total sites... \n" if (DEBUG);
	
	my $result_count = 0;
	my (@opt, @subopt);
	foreach my $site (@gsites) {
		my $guide_RNA = design_guide_RNA($site);
		$site->{'guide'} = $guide_RNA;
		$site->{'name'} = "$construct$result_count";
		# TargetFinder
		my ($off_targets, $on_targets, @json) = off_target_check($site, $mRNAdb, "$construct$result_count");
		my ($star, $oligo1, $oligo2) = oligo_designer($guide_RNA, $fb);
		$site->{'tf'} = \@json;
		$site->{'star'} = $star;
		$site->{'oligo1'} = $oligo1;
		$site->{'oligo2'} = $oligo2;
		if ($fasta) {
			if ($off_targets == 0) {
				push @opt, $site;
				$result_count++;
			} else {
				my %hash;
				$hash{'off_targets'} = $off_targets;
				$hash{'site'} = $site;
				push @subopt, \%hash;
			}
		} else {
			if ($off_targets == 0 && $on_targets == $target_count) {
				push @opt, $site;
				$result_count++;
			} else {
				my %hash;
				$hash{'off_targets'} = $off_targets;
				$hash{'site'} = $site;
				push @subopt, \%hash;
			}
		}
		last if ($result_count == 3);
	}
	
	@subopt = sort {$a->{'off_targets'} <=> $b->{'off_targets'}} @subopt;
	
	$result_count = 1;
	print "{\n";
	print '  "optimal": {'."\n";
	
	my @json;
	foreach my $site (@opt) {
		@{$site->{'tf'}}[1] =~ s/amiRNA\d+/amiRNA Result $result_count/;
	
		my $json = '    "'.$construct.' Result '.$result_count.'": {'."\n";
		$json .=   '      "'.$construct.'": "'.$site->{'guide'}.'",'."\n";
		$json .=   '      "'.$construct.'*": "'.$site->{'star'}.'",'."\n";
		$json .=   '      "oligo1": "'.$site->{'oligo1'}.'",'."\n";
		$json .=   '      "oligo2": "'.$site->{'oligo2'}.'",'."\n";
		$json .=   '      "TargetFinder": '.join("\n      ", @{$site->{'tf'}})."\n";
		$json .=   '    }';
		push @json, $json;
		$result_count++;
	}
	print join(",\n", @json)."\n";
	print '  },'."\n";
	print '  "suboptimal": {'."\n";
	
	my $result = 1;
	@json = ();
	foreach my $ssite (@subopt) {
		my $site = \%{$ssite->{'site'}};
		
		@{$site->{'tf'}}[1] =~ s/$construct\d+/$construct Result $result_count/;
		
		my $json = '    "'.$construct.' Result '.$result_count.'": {'."\n";
		$json .=   '      "'.$construct.'": "'.$site->{'guide'}.'",'."\n";
		$json .=   '      "'.$construct.'*": "'.$site->{'star'}.'",'."\n";
		$json .=   '      "oligo1": "'.$site->{'oligo1'}.'",'."\n";
		$json .=   '      "oligo2": "'.$site->{'oligo2'}.'",'."\n";
		$json .=   '      "TargetFinder": '.join("\n      ", @{$site->{'tf'}})."\n";
		$json .=   '    }';
		push @json, $json;
		last if ($result == 3);
		$result++;
		$result_count++;
	}
	print join(",\n", @json)."\n";
	print '  }'."\n";
	print "}\n";
}

## Get target sequences
#if ($fasta) {
#	$ids = build_fg_index_fasta($fasta);
#} else {
#	$ids = build_fg_index(@accessions);
#}

# Find sites
#if ($opt{'o'}) {
#	@t_sites = get_tsites($ids, $seed, 1);
#} else {
#	@t_sites = get_tsites($ids, $seed, 0);
#}

# Group sites
#my @gsites = group_tsites($seed, @t_sites);

# Scoring sites
#my $target_count = scalar(keys(%{$ids}));
#@gsites = score_sites($target_count, $seed, @gsites);

#print STDERR "Sorting and outputing results... \n" if (DEBUG);
##@gsites = sort {$a->{'distance'} <=> $b->{'distance'} || $a->{'score'} cmp $b->{'score'}} @gsites;
#@gsites = sort {
#	$a->{'other_mm'} <=> $b->{'other_mm'}
#		||
#	$a->{'p21'} <=> $b->{'p21'}
#		||
#	$a->{'p3'} <=> $b->{'p3'}
#		||
#	$a->{'p2'} <=> $b->{'p2'}
#		||
#	$a->{'p1'} <=> $b->{'p1'}
#	} @gsites;

#print STDERR "Analyzing ".scalar(@gsites)." total sites... \n" if (DEBUG);

# Design and test guide RNAs
# Add rules for site searches. For example:
     # How many results do we want to return?
		 # Are there site types we do not want to accept?
#my $result_count = 0;
#my (@opt, @subopt);
#foreach my $site (@gsites) {
#	my $guide_RNA = design_guide_RNA($site);
#	$site->{'guide'} = $guide_RNA;
#	$site->{'name'} = "amiRNA$result_count";
#	# TargetFinder
#	my ($off_targets, $on_targets, @json) = off_target_check($site, $mRNAdb, "amiRNA$result_count");
#	my ($star, $oligo1, $oligo2) = oligo_designer($guide_RNA, $fb);
#	$site->{'tf'} = \@json;
#	$site->{'star'} = $star;
#	$site->{'oligo1'} = $oligo1;
#	$site->{'oligo2'} = $oligo2;
#	if ($fasta) {
#		if ($off_targets == 0) {
#			push @opt, $site;
#			$result_count++;
#		} else {
#			my %hash;
#			$hash{'off_targets'} = $off_targets;
#			$hash{'site'} = $site;
#			push @subopt, \%hash;
#		}
#	} else {
#		if ($off_targets == 0 && $on_targets == $target_count) {
#			push @opt, $site;
#			$result_count++;
#		} else {
#			my %hash;
#			$hash{'off_targets'} = $off_targets;
#			$hash{'site'} = $site;
#			push @subopt, \%hash;
#		}
#	}
#	last if ($result_count == 3);
#}
#
#@subopt = sort {$a->{'off_targets'} <=> $b->{'off_targets'}} @subopt;
#
#$result_count = 1;
#print "{\n";
#print '  "optimal": {'."\n";
##print "Accessions\tSites\tAdjusted distance\tp3\tp2\tp1\tp21\n";
#my @json;
#foreach my $site (@opt) {
#	#my @inc = split /;/, $site->{'names'};
#	#next if (scalar(@inc) < scalar(keys(%{$ids})));
#	#print $site->{'names'}."\t".$site->{'seqs'}."\t".$site->{'distance'}."\t".$site->{'score'}."\n";
#	#print $site->{'names'}."\t".$site->{'seqs'}."\t".$site->{'other_mm'}."\t".$site->{'p3'}."\t".$site->{'p2'}."\t".$site->{'p1'}."\t".$site->{'p21'}."\t".$site->{'guide'}."\n";
#	
#	@{$site->{'tf'}}[1] =~ s/amiRNA\d+/amiRNA Result $result_count/;
#	
#	my $json = '    "amiRNA Result '.$result_count.'": {'."\n";
#	$json .=   '      "amiRNA": "'.$site->{'guide'}.'",'."\n";
#	$json .=   '      "amiRNA*": "'.$site->{'star'}.'",'."\n";
#	$json .=   '      "oligo1": "'.$site->{'oligo1'}.'",'."\n";
#	$json .=   '      "oligo2": "'.$site->{'oligo2'}.'",'."\n";
#	$json .=   '      "TargetFinder": '.join("\n      ", @{$site->{'tf'}})."\n";
#	$json .=   '    }';
#	push @json, $json;
#	$result_count++;
#}
#print join(",\n", @json)."\n";
#print '  },'."\n";
#print '  "suboptimal": {'."\n";
#my $result = 1;
#@json = ();
#foreach my $ssite (@subopt) {
#	my $site = \%{$ssite->{'site'}};
#	
#	@{$site->{'tf'}}[1] =~ s/amiRNA\d+/amiRNA Result $result_count/;
#	
#	my $json = '    "amiRNA Result '.$result_count.'": {'."\n";
#	$json .=   '      "amiRNA": "'.$site->{'guide'}.'",'."\n";
#	$json .=   '      "amiRNA*": "'.$site->{'star'}.'",'."\n";
#	$json .=   '      "oligo1": "'.$site->{'oligo1'}.'",'."\n";
#	$json .=   '      "oligo2": "'.$site->{'oligo2'}.'",'."\n";
#	$json .=   '      "TargetFinder": '.join("\n      ", @{$site->{'tf'}})."\n";
#	$json .=   '    }';
#	push @json, $json;
#	last if ($result == 3);
#	$result++;
#	$result_count++;
#}
#print join(",\n", @json)."\n";
#print '  }'."\n";
#print "}\n";
exit;
################################################################################
# End main
################################################################################

################################################################################
# Begin functions
################################################################################

########################################
# Function: build_fg_index_fasta
# Parses sequences in FASTA-format and builds the foreground index
########################################

sub build_fg_index_fasta {
	my $fasta = shift;
	my %ids;

	print STDERR "Building foreground index... " if (DEBUG);
	my @fasta = split /\n/, $fasta;
	my $id;
	for (my $i = 0; $i < scalar(@fasta); $i++) {
		next if ($fasta[$i] =~ /^\s*$/);
		if (substr($fasta[$i],0,1) eq '>') {
			$id = substr($fasta[$i],1);
			$ids{$id} = '';
			#$ids{$id}->{$id} = '';
		} else {
			$ids{$id} .= $fasta[$i];
			#$ids{$id}->{$id} .= $fasta[$i];
		}
	}
	print STDERR scalar(keys(%ids))." sequences loaded..." if (DEBUG);
	print STDERR "done\n" if (DEBUG);
	
	return \%ids;
}

########################################
# Function: build_fg_index
# Adds gene accessions to the foreground index
########################################
sub build_fg_index {
	my @accessions = @_;
	my %ids;
	
	print STDERR "Building foreground index... " if (DEBUG);
	my $sth = $dbh->prepare("SELECT * FROM `annotation` WHERE `transcript` LIKE ?");
	foreach my $accession (@accessions) {
		# If the user entered transcript IDs we need to convert to gene IDs
		$accession =~ s/\.\d+$//;
		
		# Get transcript names
		$sth->execute("$accession%");
		while (my $result = $sth->fetchrow_hashref) {
			#$ids{$accession}->{$result->{'transcript'}} = '';	
			$ids{$result->{'transcript'}} = '';
			open FASTA, "samtools faidx $mRNAdb $result->{'transcript'} |";
			while (my $line = <FASTA>) {
				next if (substr($line,0,1) eq '>');
				chomp $line;
				#$ids{$accession}->{$result->{'transcript'}} .= $line;
				$ids{$result->{'transcript'}} .= $line;
			}
			close FASTA;
		}
	}
	print STDERR "done\n" if (DEBUG);

	return \%ids;
}

########################################
# Function: get_tsites
# Identify all putative target sites
########################################
sub get_tsites {
	my $ids = shift;
	my $seed = shift;
	my $bg = shift;
	
	my @t_sites;
	my $site_length = 21;
	my $offset = $site_length - $seed - 1;
	
	print STDERR "Finding sites in foreground transcripts... \n" if (DEBUG);
	my $sth = $dbh->prepare("SELECT * FROM `kmers` WHERE `kmer` = ?");
	while (my ($transcript, $seq) = each(%{$ids})) {
		my $length = length($seq);
		print STDERR "  Transcript $transcript is $length nt long\n" if (DEBUG);
		for (my $i = 0; $i <= $length - $site_length; $i++) {
			my $site = substr($seq,$i,$site_length);
			my $kmer = substr($site,$offset,$seed);
			if ($bg) {
				my $is_bg = 0;
				$sth->execute($kmer);
				while (my $result = $sth->fetchrow_hashref) {
					my @accessions = split /,/, $result->{'transcripts'};
					foreach my $accession (@accessions) {
						if (!exists($ids->{$accession})) {
							$is_bg = 1;
							last;
						}
					}
				}
				next if ($is_bg == 1);
			}
			my %hash;
			$hash{'name'} = $transcript;
			$hash{'seq'} = $site;
			push @t_sites, \%hash;
		}
	}
	
	return @t_sites;
}

########################################
# Function: group_tsites
# Group target sites based on seed sequence
########################################
sub group_tsites {
	my $seed = shift;
	my @t_sites = @_;
	
	my $site_length = 21;
	my $offset = $site_length - $seed - 1;
	
	print STDERR "Grouping sites... " if (DEBUG);
	@t_sites = sort {substr($a->{'seq'},$offset,$seed) cmp substr($b->{'seq'},$offset,$seed) || $a->{'name'} cmp $b->{'name'}} @t_sites;
	
	my (@names, $lastSeq, @seqs, @gsites);
	my $score = 0;
	my $i = 0;
	foreach my $row (@t_sites) {
		if (scalar(@names) == 0) {
			$lastSeq = $row->{'seq'};
		}
		if (substr($lastSeq,$offset,$seed) eq substr($row->{'seq'},$offset,$seed)) {
			push @names, $row->{'name'};
			push @seqs, $row->{'seq'};
			#$score += $row->{'ideal'};
		} else {
			my %hash;
			$hash{'names'} = join(";",@names);
			$hash{'seqs'} = join(";", @seqs);
			#$hash{'score'} = $score;
			
			# Edit distances
			#if (scalar(@names) > 1) {
			#	my @distances = adist(@seqs);
			#	@distances = sort {$b <=> $a} @distances;
			#	$hash{'distance'} = $distances[0];
			#} else {
			#	$hash{'distance'} = 0;
			#}
			push @gsites, \%hash;
			
			@names = $row->{'name'};
			@seqs = $row->{'seq'};
			#$score = $row->{'ideal'};
			
			$lastSeq = $row->{'seq'};
			if ($i == scalar(@t_sites) - 1) {
				my %last;
				$last{'names'} = $row->{'name'};
				$last{'seqs'} = $row->{'seq'};
				#$last{'score'} = $row->{'ideal'};
				#$last{'distance'} = 0;
			}
		}
		$i++;
	}
	print STDERR "done\n" if (DEBUG);
	
	return @gsites;
}

########################################
# Function: score_sites
# Scores sites based on similarity
########################################
sub score_sites {
	my $min_site_count = shift;
	my $seed = shift;
	my @gsites = @_;
	my $site_length = 21;
	my $offset = $site_length - $seed - 1;
	my @scored;
	
	# Score sites on:
	#     Pos. 1
	#     Pos. 2
	#     Pos. 3
	#     Non-seed sites
	#     Pos. 21
	
	foreach my $site (@gsites) {
		my @sites = split /;/, $site->{'seqs'};
		
		next if (scalar(@sites) < $min_site_count);
		# Get the max edit distance for this target site group
		#if (scalar(@sites) > 1) {
		#	# All distances relative to sequence 1
		#	my @distances = adist(@sites);
		#	# Max edit distance
		#	@distances = sort {$b <=> $a} @distances;
		#	if ($distances[0] < 0) {
		#		$distances[0] = 0;
		#	}
		#	$site->{'distance'} = $distances[0];
		#} else {
		#	$site->{'distance'} = 0;
		#}
		
		
		# Score sites on position 21
		for (my $i = 20; $i <= 20; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			if ($nts{'A'} == scalar(@sites)) {
				# Best sites have an A to pair with the miRNA 5'U
				$site->{'p21'} = 1;
			} elsif ($nts{'G'} == scalar(@sites)) {
				# Next-best sites have a G to have a G:U bp with the miRNA 5'U
				$site->{'p21'} = 2;
			} elsif ($nts{'A'} + $nts{'G'} == scalar(@sites)) {
				# Sites with mixed A and G can both pair to the miRNA 5'U, but not equally well
				$site->{'p21'} = 3;
				# Adjust distance due to mismatch at pos 21 because we account for it here
				#$site->{'distance'}--;
			} elsif ($nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				# All other sites will not match the miRNA 5'U, but this might be okay if no other options are available
				$site->{'p21'} = 4;
			} else {
				# All other sites will not match the miRNA 5'U, but this might be okay if no other options are available
				$site->{'p21'} = 4;
				# Adjust distance due to mismatch at pos 21 because we account for it here
				#$site->{'distance'}-- if (scalar(@sites) > 1);
			}
		}
		
		# Score sites on position 1
		for (my $i = 0; $i <= 0; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			# Pos 1 is intentionally mismatched so any base is allowed here
			# However, if G and T bases are present together then pairing is unavoidable due to G:U base-pairing
			if ($nts{'A'} == scalar(@sites) || $nts{'G'} == scalar(@sites) || $nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				$site->{'p1'} = 1;
			} elsif ($nts{'G'} > 0 && $nts{'T'} > 0) {
				$site->{'p1'} = 2;
				# Adjust distance due to mismatch at pos 1 because we account for it here
				#$site->{'distance'}--;
			} else {
				$site->{'p1'} = 1;
				# Adjust distance due to mismatch at pos 1 because we account for it here
				#$site->{'distance'}--;
			}
		}
		
		# Score sites on position 2
		for (my $i = 1; $i <= 1; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			# We want to pair this position, but it is not required for functionality
			if ($nts{'A'} == scalar(@sites) || $nts{'G'} == scalar(@sites) || $nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				# We can pair all of these sites
				$site->{'p2'} = 1;
			} elsif ($nts{'G'} > 0 && $nts{'A'} > 0 && $nts{'G'} + $nts{'A'} == scalar(@sites)) {
				# We can pair or G:U pair all of these sites
				$site->{'p2'} = 2;
				# Adjust distance due to mismatch at pos 2 because we account for it here
				#$site->{'distance'}--;
			} else {
				# Some of these will be unpaired
				$site->{'p2'} = 3;
				# Adjust distance due to mismatch at pos 2 because we account for it here
				#$site->{'distance'}--;
			}
		}
		
		# Score sites on position 3
		for (my $i = 2; $i <= 2; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			# The miRNA is fixed at position 19 (C) so ideally we will have a G at position 3 of the target site
			# However, mismatches can be tolerated here
			if ($nts{'G'} == scalar(@sites)) {
				$site->{'p3'} = 1;
			} elsif ($nts{'A'} == scalar(@sites) || $nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				$site->{'p3'} = 2;
			} else {
				$site->{'p3'} = 3;
				# Adjust distance due to mismatch at pos 2 because we account for it here
				#$site->{'distance'}--;
			}
		}
		
		# Score remaining sites
		$site->{'other_mm'} = 0;
		for (my $i = 3; $i < $offset; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			unless ($nts{'A'} == scalar(@sites) || $nts{'G'} == scalar(@sites) || $nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				$site->{'other_mm'}++;
			}
		}
		
		push @scored, $site;
	}
	
	return @scored;
}

########################################
# Function: design_guide_RNA
# Designs the guide RNA based on the
# target site sequence(s)
########################################
sub design_guide_RNA {
	my $site = shift;
	my $guide;
	
	my %mm = (
		'A' => 'A',
		'C' => 'C',
		'G' => 'G',
		'T' => 'T',
		'AC' => 'A',
		'AG' => 'A',
		'AT' => 'C',
		'CG' => 'A',
		'CT' => 'C',
		'ACG' => 'A',
		'ACT' => 'C',
		'GT' => 'G',
		'AGT' => 'G',
		'CGT' => 'T',
		'ACGT' => 'A'
	);
	
	my %bp = (
		'A' => 'T',
		'C' => 'G',
		'G' => 'C',
		'T' => 'A',
		'AC' => 'T',
		'AG' => 'T',
		'AT' => 'T',
		'CG' => 'C',
		'CT' => 'G',
		'ACG' => 'T',
		'ACT' => 'G',
		'GT' => 'C',
		'AGT' => 'T',
		'CGT' => 'A',
		'ACGT' => 'T'
	);

	# Format of site data structure
	#$site->{'names'}
	#$site->{'seqs'}
	#$site->{'other_mm'}
	#$site->{'p3'}
	#$site->{'p2'}
	#$site->{'p1'}
	#$site->{'p21'}
	my @sites = split /;/, $site->{'seqs'};
	
	# Create guide RNA string
	for (my $i = 0; $i <= 20; $i++) {
		my %nts = (
			'A' => 0,
			'C' => 0,
			'G' => 0,
			'T' => 0
		);
		
		# Index nucleotides at position i
		foreach my $seq (@sites) {
			$nts{substr($seq,$i,1)}++;
		}
		
		# Create a unique nt diversity screen for choosing an appropriate base pair
		my $str;
		foreach my $nt ('A','C','G','T') {
			if ($nts{$nt} > 0) {
				$str .= $nt;
			}
		}
		
		if ($i == 0) {
			# Pos 1 is intentionally mismatched so any base is allowed here
			# However, if G and T bases are present together then pairing is unavoidable due to G:U base-pairing
			$guide .= $mm{$str};
		} elsif ($i == 2) {
			# Pos 3 is fixed as a C to pair the the 5'G of the miRNA*
			$guide .= 'C';
		} elsif ($i == 20) {
			# Pos 21, all guide RNAs have a 5'U
			$guide .= 'T';
		} else {
			# All other positions are base paired
			$guide .= $bp{$str};
		}
	}
	
	return reverse $guide;
}

########################################
# Function: Off-target check
#   Use TargetFinder to identify the
#   spectrum of predicted target RNAs
########################################
sub off_target_check {
	my $site = shift;
	my $mRNAdb = shift;
	my $name = shift;
	
	# Format of site data structure
	#$site->{'names'}
	#$site->{'seqs'}
	#$site->{'other_mm'}
	#$site->{'p3'}
	#$site->{'p2'}
	#$site->{'p1'}
	#$site->{'p21'}
	#$site->{'guide'}
	
	my $offCount = 0;
	my $onCount = 0;
	my @json;
	my $sth = $dbh->prepare("SELECT * FROM `annotation` WHERE `transcript` = ?");
	open TF, "$targetfinder -s $site->{'guide'} -d $mRNAdb -q $name -p json |";
	while (my $line = <TF>) {
		chomp $line;
		push @json, $line;
		if ($line =~ /Target accession/) {
			my ($tag, $transcript) = split /\:\s/, $line;
			$transcript =~ s/",*//g;
			
			$sth->execute($transcript);
			my $result = $sth->fetchrow_hashref;
			if ($result->{'description'}) {
				$result->{'description'} = decode_entities($result->{'description'});
				$result->{'description'} = encode_entities($result->{'description'});
				$result->{'description'} =~ s/;//g;
				push @json, '        "Target description": "'.$result->{'description'}.'",';
			} else {
				push @json, '        "Target description": "unknown",';
			}
			
			if ($site->{'names'} =~ /$transcript/) {
				$onCount++;
			} else {
				$offCount++;
			}
		}
	}
	close TF;
	return ($offCount, $onCount, @json);
}

########################################
# Function: oligo_designer
# Generates cloning oligonucleotide sequences
########################################
sub oligo_designer {
	my $guide = shift;
	my $type = shift;
	
	my $rev = reverse $guide;
	$rev =~ tr/ACGTacgt/TGCAtgca/;
	
	my @temp = split //, $rev;
	my $c = $temp[10];
	my $g = $temp[2];
	my $n = $temp[20];
	
	$c =~ tr/[AGCT]/[CTAG]/;
	
	my ($star1, $oligo1, $oligo2, $realstar, $string, $bsa1, $bsa2);
	if ($type eq 'eudicot') {
		$star1 = substr($rev,0,10).$c.substr($rev,11,10);
		$oligo1 = $guide.'ATGATGATCACATTCGTTATCTATTTTTT'.$star1;
		$oligo2 = reverse $oligo1;
		$oligo2 =~ tr/ACTGacgt/TGACtgca/;
		$realstar = substr($star1,2,20);
		$realstar = $realstar.'CA';
		$string = 'AGTAGAGAAGAATCTGTA'.$oligo1.'CATTGGCTCTTCTTACT';
		$bsa1 = 'TGTA';
		$bsa2 = 'AATG';
	} elsif ($type eq 'monocot') {
		$star1 = substr($rev,0,10).$c.substr($rev,11,9).'C';
		$oligo1 = $guide.'ATGATGATCACATTCGTTATCTATTTTTT'.$star1;
		$oligo2 = reverse $oligo1;
		$oligo2 =~ tr/ATGCatgc/TACGtacg/;
		$realstar = substr($star1,2,20);
		$realstar = $realstar.'CA';
		$string = 'GGTATGGAACAATCCTTG'.$oligo1.'CATGGTTTGTTCTTACC';
		$bsa1 = 'CTTG';
		$bsa2 = 'CATG';
	} else {
		print STDERR " Foldback type $type not supported.\n\n";
		exit 1;
	}

	return ($realstar, $bsa1.$oligo1, $bsa2.$oligo2);
}

########################################
# Function: parse_list
# Parses deliminated lists into an array
########################################
sub parse_list {
	my $sep = shift;
  my ($flatList) = @_;
  my @final_list;

  # put each deliminated entry in an array
  if ($flatList =~ /$sep/) {
    @final_list = split (/$sep/,$flatList);
  } else {
    push(@final_list,$flatList);
  }
 return @final_list;
}

########################################
# Function: arg_check
# Parse Getopt variables
########################################
sub arg_check {
	if ($opt{'h'}) {
		arg_error();
	}
	if (!$opt{'a'} && !$opt{'f'}) {
		arg_error('An input sequence or a gene accession ID were not provided!');
	}
	if ($opt{'a'}) {
		@accessions = parse_list(',', $opt{'a'});
		if ($opt{'s'}) {
			$species = $opt{'s'};
		} else {
			arg_error('A species name was not provided!');
		}
	}
	if ($opt{'f'}) {
		$fasta = $opt{'f'};
		if ($opt{'s'}) {
			$species = $opt{'s'};
		}
	}
	if ($opt{'t'}) {
		$fb = $opt{'t'};
	} else {
		$fb = 'eudicot';
	}
	if ($opt{'c'}) {
		$construct = $opt{'c'};
	} else {
		$construct = 'amiRNA';
	}
	
}

########################################
# Funtion: arg_error
# Process input errors and print help
########################################
sub arg_error {
  my $error = shift;
  if ($error) {
    print STDERR $error."\n";
  }
  my $usage = "
usage: psams.pl [-f FASTA] [-a ACCESSIONS -s SPECIES] [-t FOLDBACK] [-c CONSTRUCT] [-o] [-h]

Plant Small RNA Maker Suite (P-SAMS).
  Artificial microRNA and synthetic trans-acting siRNA designer tool.

arguments:
  -t FOLDBACK           Foldback type [eudicot]. Default = eudicot.
  -f FASTA              FASTA-formatted sequence. Not used if -a is set.
  -a ACCESSION          Gene accession(s). Comma-separated list. Not used if -f is set.
  -s SPECIES            Species. Required if -a is set.
  -c CONSTRUCT          Construct type (amiRNA, syntasiRNA). Default = amiRNA.
  -o                    Predict off-target transcripts? Filters guide sequences to minimize/eliminate off-targets.
  -h                    Show this help message and exit.

  ";
  print STDERR $usage;
  exit 1;
}

################################################################################
# End functions
################################################################################