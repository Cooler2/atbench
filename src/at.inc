{ ATBench - common compiler switches.
  Included by every unit. Checks stay OFF everywhere: a range check firing
  inside a benchmark kernel would be exactly the "Runtime Error because the
  CPU was too fast/slow" failure mode we are trying to make impossible. }

{$ASMMODE INTEL}
{$R-}   { no range checking   }
{$Q-}   { no overflow checking - counters are meant to wrap }
{$S-}   { no stack checking   }
{$I-}   { no automatic I/O checking - every file op tests IOResult by hand }
{$V-}   { relaxed string var checking }
{$B-}   { short-circuit boolean evaluation }
