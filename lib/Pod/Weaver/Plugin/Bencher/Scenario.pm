package Pod::Weaver::Plugin::Bencher::Scenario;

# DATE
# VERSION

use 5.010001;
use Moose;
with 'Pod::Weaver::Role::AddTextToSection';
with 'Pod::Weaver::Role::Section';

use Perinci::Result::Format::Lite;
use Bencher;

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

sub _process_module {
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

    my $scenario = Bencher::parse_scenario(
        scenario => ${"$package\::scenario"});

    my $scenario_name = $package;
    $scenario_name =~ s/\ABencher::Scenario:://;

    # add Synopsis section
    {
        my @pod;
        push @pod, "To run benchmark with default option:\n\n",
            " % bencher -m $scenario_name\n\n";
        my @pmodules = Bencher::_get_participant_modules($scenario);
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

    my @modules = Bencher::_get_participant_modules($scenario);

    # add Sample Benchmark Results section
    my ($bench_res, $fres, $f2res);
    {
        my @pod;

        $bench_res = Bencher::bencher(
            action => 'bench',
            scenario_module => $scenario_name,
        );
        $fres = Bencher::format_result($bench_res);
        $f2res = Perinci::Result::Format::Lite::format($fres, 'text-pretty');
        $f2res =~ s/^/ /gm;

        my $num_cores = $bench_res->[3]{'func.cpu_info'}[0]{number_of_cores};
        push @pod, "Run on: ",
            "perl: I<< ", __ver_or_vers($bench_res->[3]{'func.module_versions'}{perl}), " >>, ",
            "CPU: I<< ", $bench_res->[3]{'func.cpu_info'}[0]{name}, " ($num_cores cores) >>, ",
            "OS: I<< ", $bench_res->[3]{'func.platform_info'}{osname}, " ", $bench_res->[3]{'func.platform_info'}{oslabel}, " version ", $bench_res->[3]{'func.platform_info'}{osvers}, " >>, ",
            "OS kernel: I<< ", $bench_res->[3]{'func.platform_info'}{kname}, " version ", $bench_res->[3]{'func.platform_info'}{kvers}, " >>",
            ".\n\n";

        push @pod, "Benchmark with default option:\n\n", $f2res, "\n\n";

        if (@modules && !$scenario->{module_startup}) {
            $bench_res = Bencher::bencher(
                action => 'bench',
                module_startup => 1,
                scenario_module => $scenario_name,
            );
            $fres = Bencher::format_result($bench_res);
            $f2res = Perinci::Result::Format::Lite::format($fres, 'text-pretty');
            $f2res =~ s/^/ /gm;
            push @pod, "Benchmark module startup overhead:\n\n", $f2res, "\n\n";
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
        last unless @modules;
        my @pod;

        for my $mod (@modules) {
            push @pod, "L<$mod>";
            my $v = $bench_res->[3]{'func.module_versions'}{$mod};
            if ($v) {
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
        my $res = Bencher::bencher(
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
                ($p->{include_by_default} ? "" : " (not included by default)"),
                "\n\n";
            if ($p0->{summary}) {
                push @pod, $p0->{summary}, ".\n\n";
            }
            if ($p->{cmdline}) {
                push @pod, "Command line:\n\n", " $p->{cmdline}\n\n";
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

    $self->log(["Generated POD for '%s'", $filename]);
}

sub weave_section {
    my ($self, $document, $input) = @_;

    my $filename = $input->{filename};

    my $package;
    if ($filename =~ m!^lib/(Bencher/Scenario/.+)\.pm$!) {
        $package = $1;
        $package =~ s!/!::!g;
        $self->_process_module($document, $input, $package);
    }
}

1;
# ABSTRACT: Put various information from scenario into POD

=for Pod::Coverage ^(weave_section)$

=head1 SYNOPSIS

In your C<weaver.ini>:

 [-Bencher::Scenario]


=head1 DESCRIPTION

This plugin is to be used when building C<Bencher::Scenario::*> modules.
