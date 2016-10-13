package Pod::Weaver::Plugin::Bencher::Scenario;

# DATE
# VERSION

use 5.010001;
use Moose;
with 'Pod::Weaver::Role::AddTextToSection';
with 'Pod::Weaver::Role::Section';

has include_module => (is=>'rw');
has exclude_module => (is=>'rw');
has bench => (is=>'rw', default=>sub{1});
has bench_startup => (is=>'rw', default=>sub{1});
has sample_bench => (is=>'rw');
has gen_html_tables => (is=>'rw', default=>sub{0});
has result_split_fields => (is=>'rw');
has chart => (is=>'rw', default=>sub{0});

sub mvp_multivalue_args { qw(sample_bench include_module exclude_module) }

use Bencher::Backend;
use Data::Dmp;
use File::Temp;
use Perinci::Result::Format::Lite;
use Perinci::Sub::Normalize qw(normalize_function_metadata);
use Perinci::Sub::ConvertArgs::Argv qw(convert_args_to_argv);
use String::ShellQuote;

sub __ver_or_vers {
    my $v = shift;
    if (ref($v) eq 'ARRAY') {
        return join(", ", @$v);
    } else {
        return $v;
    }
}

sub _md2pod {
    require Markdown::To::POD;

    my ($self, $md) = @_;
    my $pod = Markdown::To::POD::markdown_to_pod($md);
    # make sure we add a couple of blank lines in the end
    $pod =~ s/\s+\z//s;
    $pod . "\n\n\n";
}

sub __html_result {
    my ($bench_res, $num) = @_;
    $bench_res = Bencher::Backend::format_result(
        $bench_res, undef, {render_as_text_table=>0},
    );
    $bench_res->[3]{'table.html_class'} = 'sortable-theme-bootstrap';
    my $fres = Perinci::Result::Format::Lite::format($bench_res, "html");
    $fres =~ s/(<table)/$1 data-sortable/
        or die "Can't insert 'data-sortable' to table element";
    my @res;

    push @res, "=begin HTML\n\n";
    if ($num == 1) {
        push @res, join(
            "",
            '<script src="https://code.jquery.com/jquery-3.0.0.min.js"></script>', "\n",
            '<script src="https://cdnjs.cloudflare.com/ajax/libs/sortable/0.8.0/js/sortable.min.js"></script>', "\n",
            '<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/sortable/0.8.0/css/sortable-theme-bootstrap.min.css" />', "\n",
        );
    }
    push @res, "\n$fres\n";
    push @res, q|<script>$(document).ready(function () { $("pre:contains('#table|.$num.q|#')").remove() })</script>|, "\n";
    push @res, "\n=end HTML\n\n";
    join('', @res);
}

sub _gen_chart {
    my ($self, $tempdir, $input, $pod, $envres, $table_num) = @_;

    my $zilla = $input->{zilla};

    return unless $self->chart;

    $self->log_debug(["Generating chart (table%d) ...", $table_num]);
    my $output_file = "$tempdir/bencher-result-$table_num.png";
    my $build_file  = "share/images/bencher-result-$table_num.png";
    my $chart_res = Bencher::Backend::chart_result(
        envres      => $envres,
        title       => "table$table_num",
        output_file => $output_file,
        overwrite   => 1,
    );
    if ($chart_res->[0] != 200) {
        $self->log(["Skipped generating chart (table%d): %s", $table_num, $chart_res]);
    } else {
        $self->log(["Generated chart (table%d, output file=%s)",
                    $table_num, $output_file]);
    }

    push @$pod, "#IMAGE: $build_file|$output_file\n\n";

    # this is very very dirty. we mark that we have created some chart files in
    # a temp dir, so Dist::Zilla::Plugin::Bencher::Scenario can add them to the
    # build
    $input->{zilla}->{_pwp_bs_tempdir} = $tempdir;
}

sub _process_scenario_module {
    no strict 'refs';

    my ($self, $document, $input, $package) = @_;

    my $filename = $input->{filename};

    # XXX handle dynamically generated module (if there is such thing in the
    # future)
    local @INC = ("lib", @INC);

    {
        my $package_pm = $package;
        $package_pm =~ s!::!/!g;
        $package_pm .= ".pm";
        require $package_pm;
    }

    my $tempdir = File::Temp::tempdir(CLEANUP=>1);

    my $scenario = Bencher::Backend::parse_scenario(
        scenario => ${"$package\::scenario"});

    my $scenario_name = $package;
    $scenario_name =~ s/\ABencher::Scenario:://;

    # add Synopsis section
    {
        my @pod;
        push @pod, "To run benchmark with default option:\n\n",
            " % bencher -m $scenario_name\n\n";
        my @pmodules = Bencher::Backend::_get_participant_modules($scenario);
        if (@pmodules && !$scenario->{module_startup}) {
            push @pod, "To run module startup overhead benchmark:\n\n",
                " % bencher --module-startup -m $scenario_name\n\n";
        }
        push @pod, "For more options (dump scenario, list/include/exclude/add ",
            "participants, list/include/exclude/add datasets, etc), ",
            "see L<bencher> or run C<bencher --help>.\n\n";

        $self->add_text_to_section(
            $document, join("", @pod), 'SYNOPSIS',
            {
                after_section => ['VERSION', 'NAME'],
                before_section => 'DESCRIPTION',
                ignore => 1,
            });
    }

    # add Description section
    {
        my @pod;

        push @pod, $self->_md2pod($scenario->{description})
            if $scenario->{description};

        # blurb about Bencher
        push @pod, "Packaging a benchmark script as a Bencher scenario makes ",
            "it convenient to include/exclude/add participants/datasets (either ",
            "via CLI or Perl code), send the result to a central repository, ",
            "among others . See L<Bencher> and L<bencher> (CLI) ",
            "for more details.\n\n";

        $self->add_text_to_section(
            $document, join("", @pod), 'DESCRIPTION',
            {
                after_section => ['SYNOPSIS'],
                ignore => 1,
            });
    }

    my @modules = Bencher::Backend::_get_participant_modules($scenario);

    # add Sample Benchmark Results section
    my @bench_res;
    my $table_num = 1;
    {
        my $fres;
        my @pod;

        my $sample_benches;
        if (!$self->bench) {
            $sample_benches = [];
        } elsif ($self->sample_bench && @{ $self->sample_bench }) {
            $sample_benches = [];
            my $i = -1;
            for (@{ $self->sample_bench }) {
                $i++;
                my $res = eval $_;
                $self->log_fatal(["Invalid sample_bench[$i] specification: %s", $@]) if $@;

                my $meta = normalize_function_metadata($Bencher::Backend::SPEC{bencher});
                my $cres = convert_args_to_argv(args => $res->{args}, meta => $meta);
                $self->log_fatal(["Invalid sample_bench[$i] specification: invalid args: %s - %s", $cres->[0], $cres->[1]])
                    unless $cres->[0] == 200;
                my $cmd = "C<< bencher -m $scenario_name ".join(" ", map {shell_quote($_)} @{$cres->[2]})." >>";
                if ($res->{title}) {
                    $res->{title} .= " ($cmd)";
                } else {
                    $res->{title} = "Benchmark with $cmd";
                }
                push @$sample_benches, $res;
            }
        } else {
            $sample_benches = [
                {title=>"Benchmark with default options (C<< bencher -m $scenario_name >>)", args=>{}},
            ];
        }

        last unless @$sample_benches;

        my $i = -1;
        for my $bench (@$sample_benches) {
            $i++;
            $self->log(["Running benchmark of scenario $scenario_name with args %s", $bench->{args}]);
            my $bench_res = Bencher::Backend::bencher(
                action => 'bench',
                scenario_module => $scenario_name,
                note => 'Run by '.__PACKAGE__,
                %{ $bench->{args} },
            );

            if ($i == 0) {
                my $num_cores = $bench_res->[3]{'func.cpu_info'}[0]{number_of_cores};
                push @pod, "Run on: ",
                    "perl: I<< ", __ver_or_vers($bench_res->[3]{'func.module_versions'}{perl}), " >>, ",
                    "CPU: I<< ", $bench_res->[3]{'func.cpu_info'}[0]{name}, " ($num_cores cores) >>, ",
                    "OS: I<< ", $bench_res->[3]{'func.platform_info'}{osname}, " ", $bench_res->[3]{'func.platform_info'}{oslabel}, " version ", $bench_res->[3]{'func.platform_info'}{osvers}, " >>, ",
                    "OS kernel: I<< ", $bench_res->[3]{'func.platform_info'}{kname}, " version ", $bench_res->[3]{'func.platform_info'}{kvers}, " >>",
                    ".\n\n";
            }

            if ($self->result_split_fields) {
                my $split_bench_res = Bencher::Backend::split_result(
                    $bench_res, [split /\s*[,;]\s*|\s+/, $self->result_split_fields]);
                for my $k (0..$#{$split_bench_res}) {
                    my $split_item = $split_bench_res->[$k];
                    if ($k == 0) { push @pod, "$bench->{title}:\n\n" }
                    my $fres = Bencher::Backend::format_result($split_item->[1]);
                    $fres =~ s/^/ /gm;
                    push @pod, " #table$table_num#\n", " ", dmp($split_item->[0]), "\n$fres\n";
                    push @pod, __html_result($bench_res, $table_num) if $self->gen_html_tables;
                    $self->_gen_chart($tempdir, $input, \@pod, $split_item->[1], $table_num);
                    $table_num++;
                    push @bench_res, $split_item->[1];
                }
                push @pod, "\n";
            } else {
                my $fres = Bencher::Backend::format_result($bench_res);
                $fres =~ s/^/ /gm;
                push @pod, "$bench->{title}:\n\n #table$table_num#\n$fres\n\n";
                push @pod, __html_result($bench_res, $table_num) if $self->gen_html_tables;
                $self->_gen_chart($tempdir, $input, \@pod, $bench_res, $table_num);
                $table_num++;
                push @bench_res, $bench_res;
            }
        } # for sample_benches

        if ($self->bench_startup && @modules && !$scenario->{module_startup}) {
            $self->log(["Running module_startup benchmark of scenario $scenario_name"]);
            my $bench_res2 = Bencher::Backend::bencher(
                action => 'bench',
                module_startup => 1,
                scenario_module => $scenario_name,
                note => 'Run by '.__PACKAGE__,
            );
            $fres = Bencher::Backend::format_result($bench_res2);
            $fres =~ s/^/ /gm;
            push @pod, "Benchmark module startup overhead (C<< bencher -m $scenario_name --module-startup >>):\n\n #table$table_num#\n", $fres, "\n\n";
            push @pod, __html_result($bench_res2, $table_num) if $self->gen_html_tables;
            $self->_gen_chart($tempdir, $input, \@pod, $bench_res2, $table_num);
            $table_num++;
        }

        $self->add_text_to_section(
            $document, join("", @pod), 'SAMPLE BENCHMARK RESULTS',
            {
                after_section => ['BENCHMARKED MODULES', 'SYNOPSIS'],
                before_section => 'DESCRIPTION',
            });
    }

    # add Benchmarked Modules section
    {
        my @modules = @modules;
        # add from scenario's modules property
        if ($scenario->{modules}) {
            for my $mod (keys %{ $scenario->{modules} }) {
                push @modules, $mod unless grep {$mod eq $_} @modules;
            }
            @modules = sort @modules;
        }

        last unless @modules;
        my @pod;

        push @pod, qq(Version numbers shown below are the versions used when running the sample benchmark.\n\n);

        for my $mod (@modules) {
            push @pod, "L<$mod>";
            my $v;
            for (@bench_res) {
                if (defined $_->[3]{'func.module_versions'}{$mod}) {
                    $v = $_->[3]{'func.module_versions'}{$mod};
                    last;
                }
            }
            if (defined $v) {
                push @pod, " ", __ver_or_vers($v);
            }
            push @pod, "\n\n";
        }

        $self->add_text_to_section(
            $document, join("", @pod), 'BENCHMARKED MODULES',
            {
                after_section => 'SYNOPSIS',
                before_section => ['SAMPLE BENCHMARK RESULTS', 'DESCRIPTION'],
            });
    }

    # add Benchmark Participants section
    {
        my @pod;
        my $res = Bencher::Backend::bencher(
            action => 'list-participants',
            scenario_module => $scenario_name,
            detail => 1,
        );
        push @pod, "=over\n\n";
        my $i = -1;
        for my $p (@{ $res->[2] }) {
            $i++;
            my $p0 = $scenario->{participants}[$i];
            push @pod, "=item * ", ($p->{name} // ''), " ($p->{type})",
                ($p->{include_by_default} ? "" : " (not included by default)");
            push @pod, " [".join(", ", @{$p0->{tags}})."]" if $p0->{tags};
            push @pod, "\n\n";
            if ($p0->{summary}) {
                push @pod, $p0->{summary}, ".\n\n";
            }
            if ($p->{cmdline}) {
                push @pod, "Command line:\n\n", " $p->{cmdline}\n\n";
            } elsif ($p0->{cmdline_template}) {
                my $c = $p0->{cmdline_template}; $c = dmp($c) if ref($c) eq 'ARRAY';
                push @pod, "Command line template:\n\n", " $c\n\n";
            } elsif ($p0->{fcall_template}) {
                my $val = $p0->{fcall_template}; $val =~ s/^/ /gm;
                push @pod, "Function call template:\n\n", $val, "\n\n";
            } elsif ($p0->{code_template}) {
                my $val = $p0->{code_template}; $val =~ s/^/ /gm;
                push @pod, "Code template:\n\n", $val, "\n\n";
            } elsif ($p->{module}) {
                push @pod, "L<$p->{module}>";
                if ($p->{function}) {
                    push @pod, "::$p->{function}";
                }
                push @pod, "\n\n";
            }
            push @pod, "\n\n";
        }
        push @pod, "=back\n\n";

        $self->add_text_to_section(
            $document, join("", @pod), 'BENCHMARK PARTICIPANTS',
            {
                after_section => ['BENCHMARKED MODULES'],
                before_section => ['SAMPLE BENCHMARK RESULTS'],
            });
    }

    # add Benchmarked Datasets section
    {
        last unless $scenario->{datasets} && @{ $scenario->{datasets} };
        my @pod;

        push @pod, "=over\n\n";
        for my $ds (@{ $scenario->{datasets} }) {
            push @pod, "=item * $ds->{name}";
            push @pod, " [".join(", ", @{$ds->{tags}})."]" if $ds->{tags};
            push @pod, "\n\n";
            push @pod, "$ds->{summary}\n\n" if $ds->{summary};
        }
        push @pod, "=back\n\n";

        $self->add_text_to_section(
            $document, join("", @pod), 'BENCHMARK DATASETS',
            {
                after_section => 'BENCHMARK PARTICIPANTS',
            });
    }

    $self->log(["Generated POD for '%s'", $filename]);
}

sub _list_my_scenario_modules {
    my ($self, $input) = @_;

    my @res;
    for my $file (@{ $input->{zilla}->files }) {
        my $name = $file->name;
        next unless $name =~ m!^lib/Bencher/Scenario/!;
        $name =~ s!^lib/!!; $name =~ s/\.pm$//; $name =~ s!/!::!g;
        push @res, $name;
    }
    @res;
}

sub _process_scenarios_module {
    no strict 'refs';

    my ($self, $document, $input, $package) = @_;

    my $filename = $input->{filename};

    # XXX handle dynamically generated module (if there is such thing in the
    # future)
    local @INC = ("lib", @INC);

    {
        my $package_pm = $package;
        $package_pm =~ s!::!/!g;
        $package_pm .= ".pm";
        require $package_pm;
    }

    # add list of Bencher::Scenario::* modules to Description
    {
        my @pod;
        my @scenario_mods = $self->_list_my_scenario_modules($input);
        push @pod, "This distribution contains the following L<Bencher> scenario modules:\n\n";
        push @pod, "=over\n\n";
        push @pod, "=item * L<$_>\n\n" for @scenario_mods;
        push @pod, "=back\n\n";

        $self->add_text_to_section(
            $document, join("", @pod), 'DESCRIPTION',
            {
                after_section => ['SYNOPSIS'],
                top => 1,
            });
    }

    $self->log(["Generated POD for '%s'", $filename]);
}

sub weave_section {
    my ($self, $document, $input) = @_;

    my $filename = $input->{filename};

    my $package;
    if ($filename =~ m!^lib/(Bencher/Scenario/.+)\.pm$!) {
        {
            $package = $1;
            $package =~ s!/!::!g;
            if ($self->include_module && @{ $self->include_module }) {
                last unless grep {"Bencher::Scenario::$_" eq $package} @{ $self->include_module };
            }
            if ($self->exclude_module && @{ $self->exclude_module }) {
                last if grep {"Bencher::Scenario::$_" eq $package} @{ $self->exclude_module };
            }
            $self->_process_scenario_module($document, $input, $package);
        }
    }
    if ($filename =~ m!^lib/(Bencher/Scenarios/.+)\.pm$!) {
        {
            # since Bencher::Scenario PW plugin might be called more than once,
            # we avoid duplicate processing via a state variable
            state %mem;
            last if $mem{$filename}++;
            $package = $1;
            $package =~ s!/!::!g;
            $self->_process_scenarios_module($document, $input, $package);
        }
    }
}

1;
# ABSTRACT: Plugin to use when building Bencher::Scenario::* distribution

=for Pod::Coverage .*

=head1 SYNOPSIS

In your F<weaver.ini>:

 [-Bencher::Scenario]
 ;exclude_module=Foo

=head1 DESCRIPTION

This plugin is to be used when building C<Bencher::Scenario::*> distribution.
Currently it does the following:

For each C<lib/Bencher/Scenario/*> module files:

=over

=item * Add a Synopsis section (if doesn't already exist) containing a few examples on how to use the scenario

=item * Add a description about Bencher in the Description section

=item * Add a Benchmark Participants section containing list of participants from the scenario

=item * Add a Sample Benchmark Results containing result from a bencher run

Both normal benchmark and a separate module startup benchmark (if eligible) are
run and shown.

=item * Add a Benchmarked Modules section containing list of benchmarked modules (if any) from the scenario and their versions

=back

For each C<lib/Bencher/Scenario/*> module files:

=over

=item * Add list of scenario modules at the beginning of Description section

=back


=head1 CONFIGURATION

=head2 include_module+ => str

Filter only certain scenario modules. Can be specified multiple times.

=head2 exclude_module+ => str

Exclude certain scenario modules. Can be specified multiple times.

=head2 sample_bench+ => hash

Add a sample benchmark. Value is a hash which can contain these keys: C<title>
(specify title for the benchmark), C<args> (hash arguments for bencher()). Can
be specified multiple times.

=head2 bench => bool (default: 1)

Set to 0 if you do not want to produce any sample benchmarks (including module
startup benchmark).

=head2 bench_startup => bool (default: 1)

Set to 0 if you do not want to produce module startup sample benchmark.

=head2 gen_html_tables => bool (default: 0)

=head2 result_split_fields => str

If specified, will split result table into multiple tables using the specified
fields (comma-separated). For example:

 result_split_fields = dataset

or:

 result_split_fields = participant

Note that module startup benchmark result is not split.

=head2 chart => bool (default: 0)

Whether to produce chart or not. The chart files will be stored in
F<share/images/bencher-result-N.png> where I<N> is the table number.

Note that this plugin will produce this snippets:

 # IMAGE: share/images/bencher-result-N.png

and you'll need to add the plugin L<Dist::Zilla::Plugin::InsertDistImage> to
convert it to actual HTML.


=head1 SEE ALSO

L<Bencher>

L<Dist::Zilla::Plugin::Bencher::Scenario>
