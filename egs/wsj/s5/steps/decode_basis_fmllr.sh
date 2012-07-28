#!/bin/bash

# Copyright 2012   Carnegie Mellon University (Author: Yajie Miao)
#                  Johns Hopkins University (Author: Daniel Povey)

# Decoding script that does basis fMLLR.  This can be on top of delta+delta-delta,
# or LDA+MLLT features.

# There are 3 models involved potentially in this script,
# and for a standard, speaker-independent system they will all be the same.
# The "alignment model" is for the 1st-pass decoding and to get the 
# Gaussian-level alignments for the "adaptation model" the first time we
# do fMLLR.  The "adaptation model" is used to estimate fMLLR transforms
# and to generate state-level lattices.  The lattices are then rescored
# with the "final model".
#
# The following table explains where we get these 3 models from.
# Note: $srcdir is one level up from the decoding directory.
#
#   Model              Default source:                 
#
#  "alignment model"   $srcdir/final.alimdl              --alignment-model <model>
#                     (or $srcdir/final.mdl if alimdl absent)
#  "adaptation model"  $srcdir/final.mdl                 --adapt-model <model>
#  "final model"       $srcdir/final.mdl                 --final-model <model>


# Begin configuration section
first_beam=10.0 # Beam used in initial, speaker-indep. pass
first_max_active=2000 # max-active used in initial pass.
alignment_model=
adapt_model=
final_model=
fmllr_basis=
stage=0
acwt=0.083333 # Acoustic weight used in getting fMLLR transforms, and also in 
              # lattice generation.

# Parameters in alignment of training data
scale_opts="--transition-scale=1.0 --acoustic-scale=0.1 --self-loop-scale=0.1"
align_beam=10
retry_beam=40

max_active=7000
beam=13.0
lattice_beam=6.0
nj=4
silence_weight=0.01
cmd=run.pl
si_dir=
fmllr_update_type=full
# End configuration section

[ -f ./path.sh ] && . ./path.sh; # source the path.
. parse_options.sh || exit 1;

if [ $# != 4 ]; then
   echo "Usage: steps/decode_basis_fmllr.sh [options] <graph-dir> <train-data-dir> <data-dir> <decode-dir>"
   echo " e.g.: steps/decode_basis_fmllr.sh exp/tri2b/graph_tgpr data/train_si84 data/test_dev93 exp/tri2b/decode_dev93_tgpr"
   echo "main options (for others, see top of script file)"
   echo "  --config <config-file>                   # config containing options"
   echo "  --nj <nj>                                # number of parallel jobs"
   echo "  --cmd <cmd>                              # Command to run in parallel with"
   echo "  --adapt-model <adapt-mdl>                # Model to compute transforms with"
   echo "  --alignment-model <ali-mdl>              # Model to get Gaussian-level alignments for"
   echo "                                           # 1st pass of transform computation."
   echo "  --final-model <finald-mdl>               # Model to finally decode with"
   echo "  --fmllr-basis <fmllr-basis>              # Base matrices used in fMLLR"
   echo "  --si-dir <speaker-indep-decoding-dir>    # use this to skip 1st pass of decoding"
   echo "                                           # Caution-- must be with same tree"
   echo "  --acwt <acoustic-weight>                 # default 0.08333 ... used to get posteriors"

   exit 1;
fi


graphdir=$1
train_data=$2
data=$3
dir=`echo $3 | sed 's:/$::g'` # remove any trailing slash.

srcdir=`dirname $dir`; # Assume model directory one level up from decoding directory.
train_sdata=${train_data}/split$nj;
sdata=$data/split$nj;

mkdir -p $dir/log
[[ -d $sdata && $data/feats.scp -ot $sdata ]] || split_data.sh $data $nj || exit 1;
echo $nj > $dir/num_jobs
splice_opts=`cat $srcdir/splice_opts 2>/dev/null` # frame-splicing options.

silphonelist=`cat $graphdir/phones/silence.csl` || exit 1;

# Some checks.  Note: we don't need $srcdir/tree but we expect
# it should exist, given the current structure of the scripts.
for f in $graphdir/HCLG.fst ${train_data}/feats.scp $data/feats.scp $srcdir/tree; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

## Work out name of alignment model. ##
if [ -z "$alignment_model" ]; then
  if [ -f "$srcdir/final.alimdl" ]; then alignment_model=$srcdir/final.alimdl;
  else alignment_model=$srcdir/final.mdl; fi
fi
[ ! -f "$alignment_model" ] && echo "$0: no alignment model $alignment_model " && exit 1;
##

## Judge whether the base matrices have been computed.
if [ -z "$fmllr_basis" ]; then
  stage=$[$stage-1];
fi
##

## Compute basis matrices used in fMLLR.
if [ $stage -lt 0 ]; then
  # Set up the unadapted features "$sifeats" for training set.
  if [ -f $srcdir/final.mat ]; then feat_type=lda; else feat_type=delta; fi
  echo "$0: feature type is $feat_type";
  case $feat_type in
    delta) sifeats="ark,s,cs:apply-cmvn --norm-vars=false --utt2spk=ark:${train_sdata}/JOB/utt2spk scp:${train_sdata}/JOB/cmvn.scp scp:${train_sdata}/JOB/feats.scp ark:- | add-deltas ark:- ark:- |";;
    lda) sifeats="ark,s,cs:apply-cmvn --norm-vars=false --utt2spk=ark:${train_sdata}/JOB/utt2spk scp:${train_sdata}/JOB/cmvn.scp scp:${train_sdata}/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $srcdir/final.mat ark:- ark:- |";;
    *) echo "Invalid feature type $feat_type" && exit 1;
  esac

  # Set up the adapted features "$feats" for training set.
  if [ -f $srcdir/trans.1 ]; then 
    feats="$sifeats transform-feats --utt2spk=ark:${train_sdata}/JOB/utt2spk ark:${train_sdata}/trans.JOB ark:- ark:- |";
  else
    feats="$sifeats";
  fi

  # Get the alignment of training data. 
  if [ ! -f $srcdir/fsts.1.gz ]; then
    echo "$0: compiling graphs of transcripts"
    $cmd JOB=1:$nj $dir/log/compile_graphs.JOB.log \
      compile-train-graphs $srcdir/tree $final_model $lang/L.fst \
       "ark:utils/sym2int.pl --map-oov $oov -f 2- $lang/words.txt < ${train_sdata}/JOB/text |" \
       "ark:|gzip -c >$dir/fsts.JOB.gz" || exit 1;
  else
    cp $srcdir/fsts.*.gz $dir;
  fi

  echo "$0: aligning training data"
  $cmd JOB=1:$nj $dir/log/train_align.JOB.log \
    gmm-align-compiled $scale_opts --beam=$align_beam --retry-beam=$retry_beam $final_model \
     "ark:gunzip -c $dir/fsts.JOB.gz|" "$feats" \
     "ark:|gzip -c >$dir/train.ali.JOB.gz" || exit 1;

  # Accumulate stats for basis training.
  $cmd JOB=1:$nj $dir/log/basis.acc.JOB.log \
    ali-to-post "ark:gunzip -c $dir/train.ali.JOB.gz|" ark:- \| \
    weight-silence-post $silence_weight $silphonelist $final_model ark:- ark:- \| \
    gmm-post-to-gpost $final_model "$feats" ark:- ark:- \| \
    gmm-basis-fmllr-accs-gpost --spk2utt=ark:${train_sdata}/JOB/spk2utt \
    $final_model "$sifeats" ark,s,cs:- $dir/basis.acc.JOB || exit 1; 

  # Compute the base matrices.
  $cmd $dir/log/basis.training.log \
    gmm-basis-fmllr-training $final_model $dir/fmllr.base.mats $dir/basis.acc.* || exit 1;
  fmllr_basis=$dir/fmllr.base.mats
fi
##
[ ! -f "$fmllr_basis" ] && echo "$0: no basis matrices $fmllr_basis " && exit 1;

## Do the speaker-independent decoding, if --si-dir option not present. ##
if [ -z "$si_dir" ]; then # we need to do the speaker-independent decoding pass.
  si_dir=${dir}.si # Name it as our decoding dir, but with suffix ".si".
  if [ $stage -le 0 ]; then
    steps/decode.sh --acwt $acwt --nj $nj --cmd "$cmd" --beam $first_beam --model $alignment_model --max-active $first_max_active $graphdir $data $si_dir || exit 1;
  fi
fi
##

## Some checks, and setting of defaults for variables.
[ "$nj" -ne "`cat $si_dir/num_jobs`" ] && echo "Mismatch in #jobs with si-dir" && exit 1;
[ ! -f "$si_dir/lat.1.gz" ] && echo "No such file $si_dir/lat.1.gz" && exit 1;
[ -z "$adapt_model" ] && adapt_model=$srcdir/final.mdl
[ -z "$final_model" ] && final_model=$srcdir/final.mdl
for f in $adapt_model $final_model; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done
##

## Set up the unadapted features "$sifeats" for testing set
if [ -f $srcdir/final.mat ]; then feat_type=lda; else feat_type=delta; fi
echo "$0: feature type is $feat_type";
case $feat_type in
  delta) sifeats="ark,s,cs:apply-cmvn --norm-vars=false --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | add-deltas ark:- ark:- |";;
  lda) sifeats="ark,s,cs:apply-cmvn --norm-vars=false --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $srcdir/final.mat ark:- ark:- |";;
  *) echo "Invalid feature type $feat_type" && exit 1;
esac
##

## Now get the first-pass fMLLR transforms.
## We give all the default parameters in gmm-est-basis-fmllr
if [ $stage -le 1 ]; then
  echo "$0: getting first-pass fMLLR transforms."
  $cmd JOB=1:$nj $dir/log/fmllr_pass1.JOB.log \
    gunzip -c $si_dir/lat.JOB.gz \| \
    lattice-to-post --acoustic-scale=$acwt ark:- ark:- \| \
    weight-silence-post $silence_weight $silphonelist $alignment_model ark:- ark:- \| \
    gmm-post-to-gpost $alignment_model "$sifeats" ark:- ark:- \| \
    gmm-est-basis-fmllr-gpost --spk2utt=ark:$sdata/JOB/spk2utt \
    --fmllr-min-count=200  --num-iters=10 --size-scale=0.2 \
    --step-size-iters=3 --write-weights=ark:$dir/pre_wgt.JOB \
    $adapt_model $fmllr_basis "$sifeats" ark,s,cs:- \
    ark:$dir/pre_trans.JOB || exit 1;
fi
##

pass1feats="$sifeats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk ark:$dir/pre_trans.JOB ark:- ark:- |"

## Do the main lattice generation pass.  Note: we don't determinize the lattices at
## this stage, as we're going to use them in acoustic rescoring with the larger 
## model, and it's more correct to store the full state-level lattice for this purpose.
if [ $stage -le 2 ]; then
  echo "$0: doing main lattice generation phase"
  $cmd JOB=1:$nj $dir/log/decode.JOB.log \
    gmm-latgen-faster --max-active=$max_active --beam=$beam --lattice-beam=$lattice_beam \
    --acoustic-scale=$acwt  \
    --determinize-lattice=false --allow-partial=true --word-symbol-table=$graphdir/words.txt \
    $adapt_model $graphdir/HCLG.fst "$pass1feats" "ark:|gzip -c > $dir/lat.tmp.JOB.gz" \
    || exit 1;
fi
##

## Do a second pass of estimating the transform-- this time with the lattices
## generated from the alignment model.  Compose the transforms to get
## $dir/trans.1, etc.
if [ $stage -le 3 ]; then
  echo "$0: estimating fMLLR transforms a second time."
  $cmd JOB=1:$nj $dir/log/fmllr_pass2.JOB.log \
    lattice-determinize-pruned --acoustic-scale=$acwt --beam=4.0 \
    "ark:gunzip -c $dir/lat.tmp.JOB.gz|" ark:- \| \
    lattice-to-post --acoustic-scale=$acwt ark:- ark:- \| \
    weight-silence-post $silence_weight $silphonelist $adapt_model ark:- ark:- \| \
    gmm-est-basis-fmllr --fmllr-min-count=200 \
    --spk2utt=ark:$sdata/JOB/spk2utt --write-weights=ark:$dir/trans_tmp_wgt.JOB \
    $adapt_model $fmllr_basis "$pass1feats" ark,s,cs:- ark:$dir/trans_tmp.JOB '&&' \
    compose-transforms --b-is-affine=true ark:$dir/trans_tmp.JOB ark:$dir/pre_trans.JOB \
    ark:$dir/trans.JOB  || exit 1;
fi
##

feats="$sifeats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk ark:$dir/trans.JOB ark:- ark:- |"

# Rescore the state-level lattices with the final adapted features, and the final model
# (which by default is $srcdir/final.mdl, but which may be specified on the command line,
# useful in case of discriminatively trained systems).
# At this point we prune and determinize the lattices and write them out, ready for 
# language model rescoring.

if [ $stage -le 4 ]; then
  echo "$0: doing a final pass of acoustic rescoring."
  $cmd JOB=1:$nj $dir/log/acoustic_rescore.JOB.log \
    gmm-rescore-lattice $final_model "ark:gunzip -c $dir/lat.tmp.JOB.gz|" "$feats" ark:- \| \
    lattice-determinize-pruned --acoustic-scale=$acwt --beam=$lattice_beam ark:- \
    "ark:|gzip -c > $dir/lat.JOB.gz" '&&' rm $dir/lat.tmp.JOB.gz || exit 1;
fi

[ ! -x local/score.sh ] && \
  echo "$0: not scoring because local/score.sh does not exist or not executable." && exit 1;
local/score.sh --cmd "$cmd" $data $graphdir $dir

rm $dir/{trans_tmp,pre_trans}.*

exit 0;

