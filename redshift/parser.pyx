"""
MALT-style dependency parser
"""
cimport cython
import random
import os.path
from os.path import join as pjoin
import shutil
import json

from libc.stdlib cimport malloc, free, calloc
from libc.string cimport memcpy, memset
from libcpp.vector cimport vector
from cython.operator cimport dereference as deref
from cython.operator cimport preincrement as inc

from _state cimport *
from sentence cimport Input, Sentence, Token, Step
from transitions cimport Transition, transition, fill_valid, fill_costs
from transitions cimport get_nr_moves, fill_moves
from transitions cimport *
from beam cimport Beam
from tagger cimport Tagger
from util import Config

from features.extractor cimport Extractor
import _parse_features
from _parse_features cimport *

import index.hashes
cimport index.hashes

from learn.perceptron cimport Perceptron

from libc.stdint cimport uint64_t, int64_t


VOCAB_SIZE = 1e6
TAG_SET_SIZE = 50


DEBUG = False 
def set_debug(val):
    global DEBUG
    DEBUG = val


def train(train_str, model_dir, n_iter=15, beam_width=8, train_tagger=True,
          feat_set='basic', feat_thresh=10,
          use_edit=False, use_break=False, use_filler=False):
    if os.path.exists(model_dir):
        shutil.rmtree(model_dir)
    os.mkdir(model_dir)
    cdef list sents = [Input.from_conll(s) for s in
                       train_str.strip().split('\n\n') if s.strip()]
    lattice_width, left_labels, right_labels, dfl_labels = get_labels(sents)
    Config.write(model_dir, 'config', beam_width=beam_width, features=feat_set,
                 feat_thresh=feat_thresh,
                 lattice_width=lattice_width,
                 left_labels=left_labels, right_labels=right_labels,
                 dfl_labels=dfl_labels, use_break=use_break)
    Config.write(model_dir, 'tagger', beam_width=4, features='basic',
                 feat_thresh=5)
    parser = Parser(model_dir)
    indices = list(range(len(sents)))
    cdef Input py_sent
    for n in range(n_iter):
        for i in indices:
            py_sent = sents[i]
            parser.tagger.train_sent(py_sent)
            parser.train_sent(py_sent)
        parser.guide.end_train_iter(n, feat_thresh)
        parser.tagger.guide.end_train_iter(n, feat_thresh)
        random.shuffle(indices)
    parser.guide.end_training(pjoin(model_dir, 'model.gz'))
    parser.tagger.guide.end_training(pjoin(model_dir, 'tagger.gz'))
    index.hashes.save_pos_idx(pjoin(model_dir, 'pos'))
    index.hashes.save_label_idx(pjoin(model_dir, 'labels'))
    return parser


def get_labels(sents):
    left_labels = set()
    right_labels = set()
    dfl_labels = set()
    cdef Input sent
    lattice_width = 0
    for i, sent in enumerate(sents):
        for j in range(sent.length):
            if sent.c_sent.tokens[j].is_edit:
                dfl_labels.add(sent.c_sent.tokens[j].label)
            elif sent.c_sent.tokens[j].head > j:
                left_labels.add(sent.c_sent.tokens[j].label)
            else:
                right_labels.add(sent.c_sent.tokens[j].label)
            if sent.c_sent.lattice[j].n > lattice_width:
                lattice_width = sent.c_sent.lattice[j].n
    output = (
        lattice_width,
        list(sorted(left_labels)),
        list(sorted(right_labels)),
        list(sorted(dfl_labels))
    )
    return output


def get_templates(feats_str):
    match_feats = []
    templates = _parse_features.arc_hybrid
    if 'disfl' in feats_str:
        templates += _parse_features.disfl
        templates += _parse_features.new_disfl
        templates += _parse_features.suffix_disfl
        templates += _parse_features.extra_labels
        templates += _parse_features.clusters
        templates += _parse_features.edges
        templates += _parse_features.prev_next
        match_feats = _parse_features.match_templates()
    elif 'clusters' in feats_str:
        templates += _parse_features.clusters
    if 'bitags' in feats_str:
        templates += _parse_features.pos_bigrams()
    return templates, match_feats


cdef class Parser:
    cdef object cfg
    cdef Extractor extractor
    cdef Perceptron guide
    cdef Tagger tagger
    cdef size_t beam_width
    cdef int feat_thresh
    cdef Transition* moves
    cdef uint64_t* _features
    cdef size_t* _context
    cdef size_t nr_moves

    def __cinit__(self, model_dir):
        assert os.path.exists(model_dir) and os.path.isdir(model_dir)
        self.cfg = Config.read(model_dir, 'config')
        self.extractor = Extractor(*get_templates(self.cfg.features))
        self._features = <uint64_t*>calloc(self.extractor.nr_feat, sizeof(uint64_t))
        self._context = <size_t*>calloc(_parse_features.context_size(), sizeof(size_t))

        self.feat_thresh = self.cfg.feat_thresh
        self.beam_width = self.cfg.beam_width
 
        if os.path.exists(pjoin(model_dir, 'labels')):
            index.hashes.load_label_idx(pjoin(model_dir, 'labels'))
        self.nr_moves = get_nr_moves(self.cfg.lattice_width, self.cfg.left_labels,
                                     self.cfg.right_labels,
                                     self.cfg.dfl_labels, self.cfg.use_break)
        self.moves = <Transition*>calloc(self.nr_moves, sizeof(Transition))
        fill_moves(self.cfg.lattice_width, self.cfg.left_labels,
                   self.cfg.right_labels, self.cfg.dfl_labels,
                   self.cfg.use_break, self.moves)
        
        self.guide = Perceptron(1, pjoin(model_dir, 'model.gz'))
        if os.path.exists(pjoin(model_dir, 'model.gz')):
            self.guide.load(pjoin(model_dir, 'model.gz'), thresh=int(self.cfg.feat_thresh))
        if os.path.exists(pjoin(model_dir, 'pos')):
            index.hashes.load_pos_idx(pjoin(model_dir, 'pos'))
        self.tagger = Tagger(model_dir)

    cpdef int parse(self, Input py_sent) except -1:
        cdef Sentence* sent = py_sent.c_sent
        cdef size_t p_idx, i
        if self.tagger:
            self.tagger.tag(py_sent)
        cdef Beam beam = Beam(self.beam_width, <size_t>self.moves, self.nr_moves,
                              py_sent)
        self.guide.cache.flush()
        while not beam.is_finished:
            for i in range(beam.bsize):
                fill_valid(beam.beam[i], beam.moves[i], self.nr_moves) 
                # TODO: Avoid passing sent.tokens here
                self._score_classes(beam.beam[i], beam.moves[i], sent.tokens)
            beam.extend()
        beam.fill_parse(sent.tokens)
        py_sent.segment()
        sent.score = beam.beam[0].score

    cdef int _score_classes(self, State* s, Transition* classes, Token* parse) except -1:
        fill_slots(s)
        assert not is_final(s)
        cdef SlotTokens* slots = <SlotTokens*>calloc(1, sizeof(SlotTokens))
        cdef bint cache_hit
        for i in range(self.nr_moves):
            cache_hit = False
            if classes[i].is_valid:
                transition_slots(slots, s, &classes[i])
                scores = self.guide.cache.lookup(sizeof(SlotTokens), slots, &cache_hit)
                if not cache_hit:
                    fill_context(self._context, slots, parse)
                    self.extractor.extract(self._features, self._context)
                    self.guide.fill_scores(self._features, scores)
                    classes[i].score = s.score + scores[0]
        free(slots)
        return 0

    cdef int train_sent(self, Input py_sent) except -1:
        cdef size_t i
        # TODO: Fix this...
        cdef Transition[1000] g_hist
        cdef Transition[1000] p_hist
        cdef Sentence* sent = py_sent.c_sent
        cdef size_t* gold_tags = <size_t*>calloc(sent.n, sizeof(size_t))
        for i in range(sent.n):
            gold_tags[i] = sent.tokens[i].tag
        if self.tagger:
            self.tagger.tag(py_sent)
        g_beam = Beam(self.beam_width, <size_t>self.moves, self.nr_moves, py_sent)
        p_beam = Beam(self.beam_width, <size_t>self.moves, self.nr_moves, py_sent)
        cdef Token* gold_parse = sent.tokens
        cdef double delta = 0
        cdef double max_violn = -1
        cdef size_t pt = 0
        cdef size_t gt = 0
        cdef State* p
        cdef State* g
        cdef Transition* moves
        self.guide.cache.flush()
        words = py_sent.words
        while not p_beam.is_finished and not g_beam.is_finished:
            for i in range(p_beam.bsize):
                fill_valid(p_beam.beam[i], p_beam.moves[i], self.nr_moves) 
                # TODO: Avoid passing parse here
                self._score_classes(p_beam.beam[i], p_beam.moves[i], gold_parse)
                # Fill costs so we can see whether the prediction is gold-standard
                fill_costs(p_beam.beam[i], p_beam.moves[i], self.nr_moves, gold_parse)
            p_beam.extend()
            for i in range(g_beam.bsize):
                fill_valid(g_beam.beam[i], g_beam.moves[i], self.nr_moves) 
                fill_costs(g_beam.beam[i], g_beam.moves[i], self.nr_moves, gold_parse)
                for j in range(self.nr_moves):
                    if g_beam.moves[i][j].cost != 0:
                        g_beam.moves[i][j].is_valid = False
                self._score_classes(g_beam.beam[i], g_beam.moves[i], gold_parse)
            g_beam.extend()
            g = g_beam.beam[0]; p = p_beam.beam[0] 
            delta = p.score - g.score
            if delta > max_violn and p.cost >= 1:
                max_violn = delta
                pt = p.m
                gt = g.m
                memcpy(p_hist, p.history, pt * sizeof(Transition))
                memcpy(g_hist, g.history, gt * sizeof(Transition))
        if max_violn >= 0:
            counted = self._count_feats(sent, pt, gt, p_hist, g_hist)
            self.guide.batch_update({0: counted})
        else:
            self.guide.now += 1
        for i in range(sent.n):
            sent.tokens[i].tag = gold_tags[i]
        free(gold_tags)

    cdef dict _count_feats(self, Sentence* sent, size_t pt, size_t gt,
                           Transition* phist, Transition* ghist):
        cdef size_t d, i, f
        cdef uint64_t* feats
        cdef size_t clas
        cdef State* gold_state = init_state(sent)
        cdef State* pred_state = init_state(sent)
        cdef dict counts = {}
        cdef bint seen_diff = False
        for i in range(max((pt, gt))):
            self.guide.total += 1.0
            # Find where the states diverge
            if not seen_diff and ghist[i].clas == phist[i].clas:
                self.guide.n_corr += 1.0
                transition(&ghist[i], gold_state)
                transition(&phist[i], pred_state)
                continue
            seen_diff = True
            if i < gt:
                transition(&ghist[i], gold_state)
                fill_slots(gold_state)
                gold_state.slots.move = ghist[i].clas
                fill_context(self._context, &gold_state.slots, gold_state.parse)
                self.extractor.extract(self._features, self._context)
                self.extractor.count(counts, self._features, 1.0)
            if i < pt:
                transition(&phist[i], pred_state)
                fill_slots(pred_state)
                pred_state.slots.move = phist[i].clas
                fill_context(self._context, &pred_state.slots, pred_state.parse)
                self.extractor.extract(self._features, self._context)
                self.extractor.count(counts, self._features, -1.0)
        free_state(gold_state)
        free_state(pred_state)
        return counts
