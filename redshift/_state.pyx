# cython: profile=True
import io_parse
from features cimport N_LABELS

DEF MAX_SENT_LEN = 256
DEF MAX_TRANSITIONS = MAX_SENT_LEN * 5
DEF MAX_VALENCY = 127


cdef int add_dep(State *s, size_t head, size_t child, size_t label) except -1:
    s.heads[child] = head
    s.labels[child] = label
    if child < head:
        assert s.l_valencies[head] < MAX_VALENCY
        s.l_children[head][s.l_valencies[head]] = child
        s.l_valencies[head] += 1
        s.llabel_set[head][label] = 1
    else:
        assert s.r_valencies[head] < MAX_VALENCY, s.r_valencies[head]
        s.r_children[head][s.r_valencies[head]] = child
        s.r_valencies[head] += 1
        s.rlabel_set[head][label] = 1
    return 1

cdef int del_r_child(State *s, size_t head) except -1:
    child = get_r(s, head)
    assert child > 0
    s.r_children[head][s.r_valencies[head] - 1] = 0
    s.r_valencies[head] -= 1
    old_label = s.labels[child]
    for i in range(s.r_valencies[head]):
        if s.labels[s.r_children[head][i]] == old_label:
            break
    else:
        s.rlabel_set[head][old_label] = 0
    s.heads[child] = 0
    s.labels[child] = 0

cdef int del_l_child(State *s, size_t head) except -1:
    cdef:
        size_t i
        size_t child
        int old_label
    assert s.l_valencies[head] >= 1
    child = get_l(s, head)
    old_label = s.labels[child]
    s.l_valencies[head] -= 1
    for i in range(s.l_valencies[head]):
        if s.labels[s.l_children[head][i]] == old_label:
            break
    else:
        s.llabel_set[head][old_label] = 0
    s.heads[child] = 0
    s.labels[child] = 0

cdef size_t pop_stack(State *s) except 0:
    cdef size_t popped
    assert s.stack_len > 1
    popped = s.top
    s.stack_len -= 1
    s.top = s.second
    if s.stack_len >= 2:
        s.second = s.stack[s.stack_len - 2]
    else:
        s.second = 0
    assert s.top <= s.n, s.top
    assert popped != 0
    return popped


cdef int push_stack(State *s) except -1:
    s.second = s.top
    s.top = s.i
    s.stack[s.stack_len] = s.i
    s.stack_len += 1
    assert s.top <= s.n
    s.i += 1

cdef int get_l(State *s, size_t head) except -1:
    if s.l_valencies[head] == 0:
        return 0
    return s.l_children[head][s.l_valencies[head] - 1]

cdef int get_l2(State *s, size_t head) except -1:
    if s.l_valencies[head] < 2:
        return 0
    return s.l_children[head][s.l_valencies[head] - 2]

cdef int get_r(State *s, size_t head) except -1:
    if s.r_valencies[head] == 0:
        return 0
    return s.r_children[head][s.r_valencies[head] - 1]

cdef int get_r2(State *s, size_t head) except -1:
    if s.r_valencies[head] < 2:
        return 0
    return s.r_children[head][s.r_valencies[head] - 2]


cdef int get_left_edge(State *s, size_t node) except -1:
    if s.l_valencies[node] == 0:
        return 0
    node = s.l_children[node][s.l_valencies[node] - 1]
    while s.l_valencies[node] != 0:
        node = s.l_children[node][s.l_valencies[node] - 1]
    return node

cdef int get_right_edge(State *s, size_t node) except -1:
    if s.r_valencies[node] == 0:
        return 0
    node = s.r_children[node][s.r_valencies[node] - 1]
    while s.r_valencies[node] != 0:
        node = s.r_children[node][s.r_valencies[node] - 1]
    return node

cdef State init_state(size_t n):
    # TODO: Make this more efficient, probably by storing 0'd arrays somewhere,
    # and then copying them
    cdef size_t i, j
    cdef State s
    cdef int n_labels = len(io_parse.LABEL_STRS)
    # Initialise with first word on top of stack
    s = State(n=n, t=0, score=0.0, i=2, top=1, second=0, stack_len=2, is_finished=False)
    for i in range(n):
        s.stack[i] = 0
        s.l_valencies[i] = 0
        s.r_valencies[i] = 0
        s.heads[i] = 0 
        s.labels[i] = 0
        # Ideally this shouldn't matter, if we use valencies intelligently?
        for j in range(n):
            s.l_children[i][j] = 0
            s.r_children[i][j] = 0
        for j in range(n_labels):
            s.llabel_set[i][j] = 0
            s.rlabel_set[i][j] = 0
    s.stack[1] = 1
    for i in range(MAX_TRANSITIONS):
        s.history[i] = 0
    return s