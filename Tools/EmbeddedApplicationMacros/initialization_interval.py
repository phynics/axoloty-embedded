#!/usr/bin/env python3
# Copyright (c) 2026 Axoloty contributors. Licensed under the MIT License.
"""Internal bounded CFG engine. Only final_init_proof may supply production input.

The public diagnostic CLI does not use this module. Its instruction model is
trusted only when produced in-process by the pinned, hashed objdump command.
Unknown values are top; joins lose facts rather than invent callback targets.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from pathlib import Path
import re
import struct

import first_init_stack as diagnostic

TOP = None
STACK = 1 << 48
RETURN = -(1 << 48)
SAVED = (8, 9, *range(18, 28))
CALLER = (1, 5, 6, 7, *range(10, 18), *range(28, 32))
BRANCHES = {'beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu', 'c.beqz', 'c.bnez'}
LOADS = {'lb': 1, 'lbu': 1, 'lh': 2, 'lhu': 2, 'lw': 4, 'c.lw': 4, 'c.lwsp': 4}
STORES = {'sb': 1, 'sh': 2, 'sw': 4, 'c.sw': 4, 'c.swsp': 4}
EXCEPTIONAL = {'__stack_chk_fail', '__assert_func', 'abort', 'panic_abort', 'esp_system_abort', '_esp_error_check_failed'}


class Unclosed(ValueError):
    """The supported proof rules cannot establish this edge or stack effect."""


def const(n):
    return frozenset((n,))


def union(a, b):
    if a is None or b is None:
        return None
    result = a | b
    return result if len(result) <= 32 else None


def arithmetic(a, b, operation):
    if a is None or b is None:
        return None
    if any(x < -(1<<32) for x in a | b):
        return None
    values = {operation(x, y) if abs(x) >= (1<<32) or abs(y) >= (1<<32) else operation(x,y) & 0xffffffff for x in a for y in b}
    return frozenset(values) if len(values) <= 32 else None


def register(s):
    if not re.fullmatch(r'x(?:[0-9]|[12][0-9]|3[01])', s):
        raise Unclosed(f'unsupported register {s}')
    return int(s[1:])


def operands(ins):
    return [x.strip() for x in ins.operands.split('#')[0].split(',')]


def integer(s):
    return int(s, 0)

def signed(n):
    n &= 0xffffffff
    return n if n < 0x80000000 else n - 0x100000000


@dataclass
class State:
    regs: tuple
    memory: dict
    phase: int = 0

    def merge(self, other):
        # Stack depth is not widened. A loop that grows the stack rejects proof.
        if self.regs[2] != other.regs[2]:
            raise Unclosed(f'inconsistent/dynamic SP at CFG join: {self.regs[2]} vs {other.regs[2]}')
        regs = tuple(union(a, b) for a, b in zip(self.regs, other.regs))
        memory = {key: union(value, other.memory[key]) for key, value in self.memory.items() if key in other.memory}
        return State(regs, memory, self.phase)


class Program:
    def __init__(self, firmware: bytes, firmware_text: str, rom: bytes, rom_text: str):
        import hashlib
        if hashlib.sha256(rom).hexdigest() != '788e1d38724aeb8fd974fa10c4a7b089c02627d35342ce84b9e0b12b239f3551':
            raise Unclosed('unsupported ROM bytes')
        self.rom_memcpy = 0x400004ac
        self.functions = {}
        self.names = {}
        self.instructions = {}
        self.sections = []
        self.rows = []
        self.origins = {}
        self.executable = []
        for origin, data, text in [('firmware', firmware, firmware_text), ('rom', rom, rom_text)]:
            rows, executable = diagnostic.elf32_riscv_image(data)
            self.rows.extend(rows)
            for start,end,_,_ in executable:
                if any(start < old_end and old_start < end for old_start,old_end,_,_ in self.executable):
                    raise Unclosed('overlapping executable mappings')
            self.executable.extend(executable)
            for start,end,_offset,_bytes in executable:
                section = diagnostic.Function(origin, start, end-start)
                diagnostic.parse_disassembly(text, {start:section})
                self.instructions.update((ins.address,ins) for ins in section.instructions)
            # Read immutable file-backed sections for actual callback tables.
            shoff = struct.unpack_from('<I', data, 32)[0]
            shentsize, shnum = struct.unpack_from('<HH', data, 46)
            for i in range(shnum):
                row = struct.unpack_from('<IIIIIIIIII', data, shoff + shentsize * i)
                if row[1] == 1 and row[2] & 2:
                    self.sections.append((row[3], data[row[4]:row[4]+row[5]], not bool(row[2] & 1) or 0x42000000 <= row[3] < row[3]+row[5] <= 0x42800000))
            selected = [(n, a, s, t, sec, st) for n, a, s, t, sec, st in rows
                        if t == 2 and sec != 'ABS' and any(start <= a and a+s <= end for start,end,_,_ in executable)]
            syms = '\n'.join(f'{a:08x} {s:08x} T {n}' for n,a,s,_,_,_ in selected)
            by_addr, by_name = diagnostic.parse_symbols(syms)
            diagnostic.parse_disassembly(text, by_addr, by_name)
            for address, fn in by_addr.items():
                # Validate only when reached: unrelated SDK assembly is outside
                # this proof. ELF extents, not text headings, own all bytes.
                self.functions[address] = fn
                self.origins[address] = (data, syms, origin)
                for ins in fn.instructions:
                    previous = self.instructions.setdefault(ins.address, ins)
                    if previous != ins:
                        raise Unclosed(f'conflicting decoding at {ins.address:#x}')
            self.names.update(by_name)
        self.validated = set()
        self.owners = {}

    def one(self, predicate):
        result = {fn.start for name,fn in self.names.items() if predicate(name)}
        if len(result) != 1:
            raise Unclosed(f'expected unique symbol, got {len(result)}')
        return self.functions[result.pop()]

    def function(self, address):
        fn = self.functions.get(address) or self.owners.get(address)
        if fn is None:
            # ROM vector symbols can have misleading inherited body sizes.
            # A transfer must nevertheless be covered by actual STT_FUNC bytes.
            containing = [f for f in self.functions.values() if f.start <= address < f.end]
            if not containing:
                ins = self.instructions.get(address)
                if ins and ins.mnemonic == 'jal' and operands(ins)[0] == 'x0' and ins.size == 4:
                    raw = [contents[address-start:address-start+4] for start,end,_,contents in self.executable if start <= address and address+4 <= end]
                    if len(raw) == 1 and raw[0] == int(ins.encoding,16).to_bytes(4,'little'):
                        fn = diagnostic.Function(f'vector@{address:#x}',address,4,[ins])
                        self.functions[address] = fn
                        self.validated.add(address)
                        return fn
                # LLVM can leave an anonymous helper between two STT_FUNC
                # extents. Accept only the complete executable gap, starting
                # exactly at the preceding extent's end, never a guessed suffix.
                ends = {f.end for f in self.functions.values()}
                if address in ends and address in self.instructions:
                    stops = [f.start for f in self.functions.values() if f.start > address]
                    stops += [end for start,end,_,_ in self.executable if start <= address < end]
                    end = min(stops) if stops else address
                    body = [self.instructions[pc] for pc in sorted(self.instructions) if address <= pc < end]
                    cursor = address
                    for instruction in body:
                        if instruction.address != cursor:
                            raise Unclosed('truncated anonymous executable gap')
                        raw = [contents[cursor-start:cursor-start+instruction.size]
                               for start,limit,_,contents in self.executable
                               if start <= cursor and cursor+instruction.size <= limit]
                        if len(raw) != 1 or raw[0] != int(instruction.encoding,16).to_bytes(instruction.size,'little'):
                            raise Unclosed('anonymous helper byte mismatch')
                        cursor += instruction.size
                    if cursor != end:
                        raise Unclosed('incomplete anonymous executable gap')
                    fn = diagnostic.Function(f'anonymous@{address:#x}', address, end-address, body)
                    self.functions[address] = fn
                    self.validated.add(address)
                    return fn
                raise Unclosed(f'missing STT_FUNC body at {address:#x}')
            fn = min(containing, key=lambda f: f.size)
        if fn.start not in self.validated:
            data, syms, _origin = self.origins[fn.start]
            diagnostic.validate_linked_inputs(data, syms, {fn.start: fn})
            self.validated.add(fn.start)
        self.owners[address] = fn
        return fn

    def read(self, address, size):
        matches = [data[address-start:address-start+size] for start,data,readonly in self.sections
                   if readonly and start <= address and address+size <= start+len(data)]
        if len(matches) != 1:
            return None
        return const(int.from_bytes(matches[0], 'little'))


class Engine:
    def __init__(self, program):
        self.p = program
        self.cache = {}
        self.active = []
        self.edges = set()
        self.exceptions = set()
        self.frames = {}
        self.dispatches = {}
        self.return_values = {}
        self.visited = set()
        self.call_graph = set()
        self.stage_sites = set()
        self.accesses = set()
        self.callback_bindings = set()

    def analyze(self, address, callback=None, seed=None, stop_calls=(), skip_calls=False, inline_calls=False, summaries=(), stop_pcs=(), stages=()):
        key = (address, callback)
        special = seed is not None or stop_calls or skip_calls or inline_calls or stop_pcs
        if not special and key in self.cache:
            return self.cache[key]
        if address in self.active:
            raise Unclosed(f'recursion at {address:#x}')
        self.active.append(address)
        fn = self.p.function(address)
        regs = [None] * 32
        regs[0], regs[1], regs[2] = const(0), const(RETURN), const(STACK)
        for r in SAVED:
            regs[r] = const(RETURN-r)
        if callback is not None:
            regs[11] = callback
        memory = {}
        if seed:
            regs, memory = seed
        initial_saved = {r: regs[r] for r in SAVED}
        initial_sp = regs[2]
        return_states = []
        def location(pc, regs, phase):
            # Keep alternate-link continuations disjoint. In particular ROM
            # memset saves ra in t0 across an intra-body dispatch.
            return (pc, regs[1], regs[5], regs[2], phase)
        entry_key = location(address, regs, 0)
        states = {entry_key: State(tuple(regs), memory)}
        work = deque([entry_key])
        maximum = 0
        maximum_path = []
        returns = 0
        stops = []
        count = 0
        local_max = 0
        while work:
            count += 1
            if count > 100000:
                raise Unclosed(f'abstract CFG did not converge for {fn.name}')
            current = work.popleft()
            pc = current[0]
            state = states[current]
            phase = state.phase
            self.visited.add(pc)
            if pc in stop_pcs:
                if stages and phase != len(stages):
                    raise Unclosed('interval end reached before begin/hook/end sequence')
                stops.append((pc, pc, STACK-next(iter(state.regs[2])), state))
                continue
            regs, mem = list(state.regs), dict(state.memory)
            owner = self.p.function(pc)
            ins = self.p.instructions.get(pc)
            if ins is None:
                raise Unclosed(f'missing instruction at {pc:#x}')
            m, op = ins.mnemonic, operands(ins)
            following = pc + ins.size
            sp = regs[2]
            if sp is None or len(sp) != 1:
                raise Unclosed(f'unknown/dynamic SP at {pc:#x}')
            depth = STACK-next(iter(sp))
            if depth < 0 or depth > 1 << 20:
                raise Unclosed(f'invalid/unbounded stack at {pc:#x}')
            local_max = max(local_max, depth)
            if depth > maximum:
                maximum, maximum_path = depth, [f'{owner.name}@{pc:#x}']
            targets = [following]

            def setreg(r, value):
                if r:
                    regs[r] = value

            def binary(operation, immediate=False, compressed=False):
                dest = register(op[0])
                left = regs[dest if compressed else register(op[1])]
                right = const(integer(op[-1])) if immediate else regs[register(op[-1])]
                value = arithmetic(left, right, operation)
                if dest == 2 and (value is None or len(value) != 1):
                    raise Unclosed(f'dynamic SP write at {pc:#x}')
                setreg(dest, value)

            if m in ('c.unimp', 'unimp', 'ebreak', 'c.ebreak'):
                self.exceptions.add((pc, m, 'synchronous exception; handler/interrupt stack excluded'))
                targets = []
            elif m in BRANCHES:
                target = ins.target
                if target is None:
                    raise Unclosed(f'unresolved branch at {pc:#x}')
                # All branch outcomes are retained. Refine small unsigned
                # comparisons used by ROM dispatch; never infer from proximity.
                targets = [following, target]
                if m in ('bltu', 'bgeu'):
                    a, b = register(op[0]), register(op[1])
                    # Branch edge refinement is done below per successor.
            elif m in ('c.j', 'jal', 'c.jal', 'jalr', 'c.jalr', 'c.jr'):
                rd = 0
                destinations = None
                if m in ('c.j', 'c.jal'):
                    rd = 1 if m == 'c.jal' else 0
                    destinations = const(ins.target) if ins.target is not None else None
                elif m == 'jal':
                    rd = register(op[0])
                    destinations = const(ins.target) if ins.target is not None else None
                else:
                    if m == 'jalr':
                        rd = register(op[0])
                        match = re.fullmatch(r'(-?\d+)\((x\d+)\)', op[1])
                        if match is None:
                            raise Unclosed(f'unsupported jalr at {pc:#x}')
                        base = regs[register(match[2])]
                        destinations = base if int(match[1]) == 0 and base == const(RETURN) else arithmetic(base, const(int(match[1])), lambda x,y:(x+y)&~1)
                    else:
                        rd = 1 if m == 'c.jalr' else 0
                        destinations = regs[register(op[0])]
                if destinations is None:
                    raise Unclosed(f'unknown indirect transfer at {pc:#x} ({ins.text}); r5={regs[5]},r6={regs[6]},r12={regs[12]},r13={regs[13]}')
                if RETURN in destinations:
                    if regs[2] != initial_sp:
                        raise Unclosed(f'unbalanced/ambiguous return at {pc:#x}')
                    for r in SAVED:
                        if regs[r] != initial_saved[r]:
                            raise Unclosed(f'callee-saved x{r} not restored at {pc:#x}')
                    if stages and phase == 2:
                        raise Unclosed('initializer can return without trace end')
                    returns += 1
                    return_states.append(State(tuple(regs), mem, phase))
                    targets = []
                if destinations - {RETURN}:
                    destinations = destinations - {RETURN}
                    if len(destinations) > 1:
                        self.dispatches[pc] = tuple(sorted(set(self.dispatches.get(pc,())) | destinations))
                    targets = []
                    for target in sorted(destinations):
                        target_fn = self.p.function(target)
                        if target == owner.start and rd in (0,1,5):
                            raise Unclosed(f'recursive entry call at {pc:#x}')
                        self.edges.add((owner.name, pc, target_fn.name, target, rd))
                        if target == target_fn.start and target_fn.start != owner.start and rd in (0,1,5):
                            self.call_graph.add((owner.start,target_fn.start))
                        if target_fn.name == 'swift_once':
                            if regs[10] is None or regs[11] is None:
                                raise Unclosed(f'unresolved swift_once guard/callback at {pc:#x}')
                            self.callback_bindings.add((pc,tuple(sorted(regs[10])),tuple(sorted(regs[11]))))
                        if target in stages:
                            index = stages.index(target)
                            if phase != index:
                                raise Unclosed(f'begin/hook/end order violation at {pc:#x}')
                            phase += 1
                            self.stage_sites.add((phase,pc,target,depth))
                        if target in stop_calls:
                            stops.append((pc, target, depth, State(tuple(regs), mem, phase)))
                            continue
                        if target_fn.name in EXCEPTIONAL:
                            self.exceptions.add((pc, target_fn.name, 'exceptional termination; handler stack excluded'))
                            continue
                        # Outlined alternate-link helpers and internal ROM
                        # dispatch execute in the current frame/context.
                        internal = target_fn.start == owner.start or rd in (0, 5) or (inline_calls and target not in summaries)
                        if internal:
                            setreg(rd, const(following))
                            targets.append(target)
                        else:
                            cb = regs[11] if target_fn.name == 'swift_once' else None
                            bound, path = (0, []) if skip_calls and target not in summaries else self.analyze(target, cb)
                            copy_arguments = tuple(regs[r] for r in (10,11,12))
                            exported = self.return_values.get((target, cb), []) if skip_calls and target in summaries else []
                            if depth + bound > maximum:
                                maximum, maximum_path = depth + bound, [f'{owner.name}@{pc:#x}'] + path
                            for r in CALLER:
                                setreg(r, None)
                            setreg(rd, const(following))
                            if exported:
                                for r in range(10,18):
                                    value = exported[0].regs[r]
                                    for exit_state in exported[1:]:
                                        value = union(value,exit_state.regs[r])
                                    setreg(r,value)
                            # A verified ROM byte-copy has a narrow data effect
                            # summary; stack/call effects still use its real CFG.
                            if target == self.p.rom_memcpy:
                                dst, src, length = copy_arguments
                                if all(v is not None and len(v)==1 for v in (dst,src,length)):
                                    dst,src,length = (next(iter(v)) for v in (dst,src,length))
                                    if 0 <= length <= 65536:
                                        copied = {(dst+at-src,width):value for (at,width),value in mem.items()
                                                  if src <= at and at+width <= src+length}
                                        for (at,width) in list(mem):
                                            if dst < at+width and at < dst+length:
                                                del mem[(at,width)]
                                        mem.update(copied)
                                else:
                                    # Unknown output cannot preserve callback or
                                    # data facts. ABI-owned saved-register slots
                                    # remain private under the valid-memory scope.
                                    mem = {slot:value for slot,value in mem.items()
                                           if value is not None and all(v <= RETURN for v in value)}
                            # Callees may write through arguments. Saved stack
                            # slots cannot be exposed by these initializer APIs;
                            # unknown pointed-to output facts must be forgotten.
                            targets.append(following)
            elif m in LOADS or m in STORES:
                size = LOADS.get(m, STORES.get(m))
                match = re.fullmatch(r'(-?\d+)\((x\d+)\)', op[1])
                if match is None:
                    raise Unclosed(f'unsupported memory operand at {pc:#x}')
                base = regs[register(match[2])]
                addresses = arithmetic(base, const(int(match[1])), lambda x,y:x+y)
                if addresses is not None:
                    if any(STACK-(1<<20) <= ptr < next(iter(sp)) for ptr in addresses):
                        raise Unclosed(f'memory access below allocated stack at {pc:#x}')
                    for ptr in addresses:
                        if 0 <= ptr < (1<<32):
                            self.accesses.add((pc,m,ptr,size))
                if m in LOADS:
                    value = None
                    if addresses is not None:
                        values = []
                        for ptr in addresses:
                            v = mem.get((ptr,size), self.p.read(ptr,size))
                            values.append(v)
                        if values:
                            value = values[0]
                            for v in values[1:]:
                                value = union(value,v)
                    if m in ('lb','lh') and value is not None:
                        bits = size * 8
                        value = frozenset((v if v < (1<<(bits-1)) else v-(1<<bits)) & 0xffffffff for v in value)
                    setreg(register(op[0]), value)
                elif addresses is not None and len(addresses) == 1:
                    ptr = next(iter(addresses))
                    # Retain only private stack facts. Writable globals remain
                    # unknown across loops/initialization and are not constants.
                    if STACK-(1<<20) <= ptr <= STACK:
                        for (old, width) in list(mem):
                            if old < ptr+size and ptr < old+width:
                                del mem[(old,width)]
                        mem[(ptr,size)] = regs[register(op[0])]
            elif m in ('lui','c.lui'):
                setreg(register(op[0]), const(integer(op[1]) << 12))
            elif m == 'auipc':
                setreg(register(op[0]), const((pc+(integer(op[1])<<12)) & 0xffffffff))
            elif m == 'c.li':
                setreg(register(op[0]), const(integer(op[1]) & 0xffffffff))
            elif m == 'c.mv':
                setreg(register(op[0]), regs[register(op[1])])
            elif m in ('addi','c.addi','c.addi16sp','c.addi4spn'):
                binary(lambda a,b:a+b, True, m in ('c.addi','c.addi16sp'))
            elif m in ('add','c.add'):
                binary(lambda a,b:a+b, compressed=m.startswith('c.'))
            elif m in ('sub','c.sub'):
                binary(lambda a,b:a-b, compressed=m.startswith('c.'))
            elif m in ('andi','c.andi'):
                if register(op[0]) == 2:
                    raise Unclosed(f'dynamic SP alignment at {pc:#x}')
                dest = register(op[0]); mask = integer(op[-1])
                left = regs[dest if m.startswith('c.') else register(op[1])]
                value = arithmetic(left,const(mask),lambda a,b:a&b)
                if left is None and 0 <= mask <= 31:
                    value = frozenset(n for n in range(mask+1) if n & mask == n)
                setreg(dest,value)
            elif m in ('slli','c.slli'):
                binary(lambda a,b:a<<b,True,m.startswith('c.'))
            elif m in ('srli','c.srli'):
                binary(lambda a,b:(a&0xffffffff)>>b,True,m.startswith('c.'))
            elif m in ('xori','ori'):
                binary((lambda a,b:a^b) if m=='xori' else (lambda a,b:a|b),True)
            elif m in ('or','c.or'):
                binary(lambda a,b:a|b,compressed=m.startswith('c.'))
            elif m in ('and','c.and'):
                binary(lambda a,b:a&b,compressed=m.startswith('c.'))
            elif m in ('xor','c.xor'):
                binary(lambda a,b:a^b,compressed=m.startswith('c.'))
            elif m in ('fence','fence.i','c.nop'):
                pass
            elif m in ('csrrs','csrrc','csrrw','csrrsi','csrrci','csrrwi','lr.w','lr.w.aq','sc.w','sc.w.rl'):
                setreg(register(op[0]),None)
            elif m in ('sltiu','slti','sltu','slt'):
                immediate = m.startswith('slti')
                unsigned = m.endswith('u')
                def less(a,b):
                    if unsigned:
                        a,b = a & 0xffffffff,b & 0xffffffff
                    return int(a < b) if unsigned else int(signed(a) < signed(b))
                binary(less,immediate)
            elif m in ('srai','mul','mulhu','divu','remu','xori','ori','neg','not','seqz','snez'):
                if register(op[0]) == 2:
                    raise Unclosed(f'unsupported SP arithmetic at {pc:#x}')
                setreg(register(op[0]),None)
            else:
                raise Unclosed(f'unsupported instruction at {pc:#x}: {ins.text}')
            if regs[2] is None:
                raise Unclosed(f'unknown SP at {pc:#x}')
            for target in set(targets):
                next_regs = list(regs)
                if m in ('c.beqz','c.bnez'):
                    r = register(op[0]); value = next_regs[r]
                    equal = (target == ins.target) == (m == 'c.beqz')
                    if value is not None and all(x >= -(1<<32) for x in value):
                        filtered = frozenset(x for x in value if (x == 0) == equal)
                        if not filtered:
                            continue
                        next_regs[r] = filtered
                if m in ('beq','bne','blt','bge','bltu','bgeu'):
                    a,b = register(op[0]),register(op[1])
                    less = (target == ins.target) == (m in ('beq','blt','bltu'))
                    av,bv = next_regs[a],next_regs[b]
                    if av is not None and bv is not None and all(-(1<<32) <= x < (1<<32) for x in av | bv):
                        pairs=[(x,y) for x in av for y in bv if (((x & 0xffffffff) == (y & 0xffffffff)) if m in ('beq','bne') else ((x&0xffffffff)<(y&0xffffffff)) if m.endswith('u') else signed(x)<signed(y)) == less]
                        if not pairs:
                            continue
                        next_regs[a]=frozenset(x for x,_ in pairs);next_regs[b]=frozenset(y for _,y in pairs)
                    elif m in ('bltu','bgeu') and av is not None and len(av)==1 and bv is None and not less:
                        limit=next(iter(av))
                        if 0 <= limit <= 31:
                            next_regs[b]=frozenset(range(limit+1))
                nxt = State(tuple(next_regs),mem,phase)
                successor = location(target, next_regs, phase)
                if successor in states:
                    try:
                        nxt = states[successor].merge(nxt)
                    except Unclosed as error:
                        raise Unclosed(f'{error} at {target:#x} from {pc:#x}') from error
                    if nxt == states[successor]:
                        continue
                states[successor] = nxt
                work.append(successor)
        self.active.pop()
        def acyclic(node, path):
            if node in path:
                raise Unclosed(f'recursive call/tail graph at {node:#x}')
            if node in completed:
                return
            for target in adjacency.get(node, ()):
                acyclic(target,path | {node})
            completed.add(node)
        adjacency = {}
        for caller,callee in self.call_graph:
            adjacency.setdefault(caller,set()).add(callee)
        completed = set()
        for node in adjacency:
            acyclic(node,set())
        self.frames[fn.name] = local_max
        result = (maximum, maximum_path)
        self.return_values[key] = return_states
        if not special:
            if not returns:
                raise Unclosed(f'no proven return from {fn.name}')
            self.cache[key] = result
        self.last_stops = stops
        return result


def describe(engine):
    """Return deterministic, address-based evidence for a completed analysis."""
    import hashlib
    p = engine.p
    bodies = []
    for address in sorted(p.validated):
        fn = p.functions[address]
        if any(pc in engine.visited for pc in range(fn.start,fn.end,2)):
            body = b''.join(int(ins.encoding,16).to_bytes(ins.size,'little') for ins in fn.instructions)
            bodies.append({'start':fn.start,'endExclusive':fn.end,'symbol':fn.name,
                           'aliases':dict(sorted(fn.symbol_sizes.items())),
                           'bodySha256':hashlib.sha256(body).hexdigest(),
                           'origin':p.origins[address][2] if address in p.origins else 'complete-executable-gap-or-vector'})
    return {
        'validatedBodies':bodies,
        'swiftOnceBindings':[{'pc':pc,'guardAddresses':list(guards),'callbackTargets':list(targets)}
                             for pc,guards,targets in sorted(engine.callback_bindings)],
        'edges': [{'caller':a, 'pc':pc, 'callee':b, 'target':target, 'linkRegister':rd}
                  for a,pc,b,target,rd in sorted(engine.edges)],
        'computedDispatches': [{'pc':pc, 'targets':list(targets)}
                               for pc,targets in sorted(engine.dispatches.items())],
        'exceptionalExits': [{'pc':pc, 'operation':op, 'scope':scope}
                             for pc,op,scope in sorted(engine.exceptions)],
        'entryDepthMaxima': dict(sorted(engine.frames.items())),
        'visitedInstructionCount': len(engine.visited),
    }


def prove(program, configured_stack, required_guards=()):
    """Prove the selected firmware's synchronous first-init interval.

    Stack capacity is a configured physical resource. No policy constant or
    observed watermark participates in the upper-bound calculation.
    """
    p = program
    def named(name):
        return p.one(lambda n:n == name).start
    main, app, entry = (named(n) for n in ('main_task','app_main','axoloty_application_main'))
    hook = p.one(lambda n:'DeviceSmokeO21initializeStaticState' in n).start
    begin = p.one(lambda n:'EmbeddedPlatformCapabilitiesV14beginHeapTrace' in n).start
    end = p.one(lambda n:'EmbeddedPlatformCapabilitiesV12endHeapTrace' in n).start
    run = p.one(lambda n:'16startDeviceSmokey' in n and 'EmbeddedApplicationResult' in n).start
    e = Engine(p)
    # The startup task creates main_task with an exact function pointer and
    # stack request. Completed setup calls do not remain on the new task stack.
    e.analyze(named('esp_startup_start_app'), skip_calls=True,
              stop_calls=(named('xTaskCreatePinnedToCore'),))
    creation = list(e.last_stops)
    if not creation or any(s.regs[10] != const(main) for _,_,_,s in creation):
        raise Unclosed('main task creation target is not closed')
    requested = {next(iter(s.regs[12])) for _,_,_,s in creation
                 if s.regs[12] is not None and len(s.regs[12]) == 1}
    if len(requested) != 1 or len(creation) != sum(s.regs[12] is not None and len(s.regs[12]) == 1 for _,_,_,s in creation):
        raise Unclosed('main task stack request is not constant')
    requested = requested.pop()
    e.analyze(named('axoloty_main_stack_size'))
    sizes = e.return_values[(named('axoloty_main_stack_size'),None)]
    if not sizes or any(s.regs[10] != const(configured_stack) for s in sizes):
        raise Unclosed('SDK configured stack differs from final compiled capacity')
    if requested < configured_stack:
        raise Unclosed('task creation reserves less than configured capacity')
    # Bind the wrapper's callback to the target passed to task creation.
    regs = [None]*32
    regs[0],regs[1],regs[2],regs[10] = const(0),const(RETURN),const(STACK),const(main)
    for r in SAVED:
        regs[r] = const(RETURN-r)
    e.analyze(named('vPortTaskWrapper'),seed=(regs,{}),skip_calls=True,stop_calls=(main,))
    def single_stop(target):
        stops = [s for _,t,_,s in e.last_stops if t == target]
        if not stops:
            raise Unclosed('caller chain does not reach initialization')
        first = stops[0]
        if any(s != first for s in stops):
            raise Unclosed('ambiguous caller state at initialization entry')
        regs = list(first.regs)
        regs[1] = const(RETURN)
        return regs,dict(first.memory)
    wrapper_seed = single_stop(main)
    e.analyze(main,seed=wrapper_seed,skip_calls=True,stop_calls=(app,))
    main_seed = single_stop(app)
    e.analyze(app,seed=main_seed,skip_calls=True,stop_calls=(entry,),
              summaries=(named('axoloty_platform_get_v1'),named('axoloty_carrier_get_v1')))
    entry_seed = single_stop(entry)
    caller_depth = STACK-next(iter(entry_seed[0][2]))
    # The initializer graph is separate from observer/setup graphs. No later
    # App.run or corpus invocation is admitted into this closure.
    initializer = Engine(p)
    hook_bound,hook_path = initializer.analyze(hook)
    # Discover the trace-end call from CFG facts, never hardcode a profile PC.
    probe = Engine(p)
    probe.analyze(entry,seed=entry_seed,skip_calls=True,stop_calls=(end,run),
                  stages=(begin,hook,end))
    end_sites = [(pc,p.instructions[pc].size) for pc,t,_,_ in probe.last_stops if t == end]
    if len(set(end_sites)) != 1:
        raise Unclosed('trace end call is not unique')
    end_pc,end_size = end_sites[0]
    total,path = e.analyze(entry,seed=entry_seed,inline_calls=True,
                           summaries=(hook,p.rom_memcpy,0x400004a8),
                           stop_calls=(run,),stop_pcs=(end_pc+end_size,),
                           stages=(begin,hook,end))
    if not e.last_stops or any(t != end_pc+end_size for _,t,_,_ in e.last_stops):
        raise Unclosed('analyzed initialization can escape into App.run')
    if {stage for stage,_,_,_ in e.stage_sites} != {1,2,3}:
        raise Unclosed('begin/hook/end execution not established')
    # Every accepted initializer leaf is instruction-closed. Also reject any
    # known allocation entry or alias reached along this graph.
    allocator = re.compile(r'(?:malloc|calloc|realloc|memalign|aligned_alloc|strdup|swift_alloc|swift_slowAlloc|swift_task_alloc)', re.I)
    aliases = {(name,address,size) for name,address,size,*_ in p.rows if allocator.search(name)}
    reached = sorted((name,address) for name,address,size in aliases if any(address <= pc < address+size for pc in initializer.visited))
    if reached:
        raise Unclosed(f'initializer reaches allocation entry: {reached}')
    guards = classify_application_guards(p,initializer,required_guards)
    if total > configured_stack:
        raise Unclosed(f'initialization bound {total} exceeds configured stack {configured_stack}')
    return {
        'status':'PASS', 'maximumStackBytes':total,
        'applicationLazyControls':sorted(guards,key=lambda row:row['address']),
        'otherSharedModuleLazyControlsOutsideHook':[{'symbol':name,'address':address,
            'scope':'outside selected application initialization; shared module also contains transport code'}
            for name,address,*_ in p.rows if name.startswith('$e10__idf_main') and name.endswith('_Wz')
            and name not in {row['symbol'] for row in guards}],
        'configuredMainTaskStackBytes':configured_stack,
        'taskCreationStackRequestBytes':requested,
        'headroomBytes':configured_stack-total,
        'callerFramesBeforeApplicationEntryBytes':caller_depth,
        'hookMaximumStackBytes':hook_bound, 'maximumPath':path,
        'hookMaximumPath':hook_path,
        'root':entry, 'hook':hook, 'begin':begin, 'end':end,
        'cutAfterTraceEndPc':end_pc+end_size,
        'stages':[{'stage':s,'pc':pc,'target':target,'liveDepthBytes':depth}
                  for s,pc,target,depth in sorted(e.stage_sites)],
        'initializerGraph':describe(initializer), 'intervalAndCallersGraph':describe(e),
        'allocatorEntriesPresent':[{'symbol':name,'address':address} for name,address,_size in sorted(aliases)],
        'initializerAllocatorEntriesReached':[],
        'scope':[
            'Synchronous task stack through trace-end return, including begin/end helpers and pre-existing caller frames.',
            'All initializer branches and returning failure paths; trap/panic handlers and asynchronous interrupt/context-switch stack are excluded and listed.',
            'Compiled ABI execution with valid memory; no memory-corruption or termination/liveness proof.',
            'ROM memcpy data movement follows the specification of the exact pinned vendor body; its frame, transfers and dispatches use instruction analysis.',
            'ESP32-C6 flash mapping is immutable; ELF SHF_WRITE on flash rodata does not make mapped flash writable.',
        ],
    }


def classify_application_guards(p, initializer, required=()):
    """Bind selected app lazy controls to the first-init graph."""
    guards = []
    seen = set()
    for name,address,size,kind,section,section_type in p.rows:
        if name.startswith('$e10__idf_main') and name.endswith('_Wz'):
            bindings = [(pc,targets) for pc,addresses,targets in initializer.callback_bindings if address in addresses]
            reads = sorted(pc for pc,op,ptr,width in initializer.accesses if ptr == address and op in LOADS)
            writes = sorted(pc for pc,op,ptr,width in initializer.accesses if ptr == address and op in STORES)
            if name not in required and not bindings and not reads and not writes:
                continue
            seen.add(name)
            if size != 4 or kind != 1 or section_type != 8:
                raise Unclosed(f'unsupported application lazy-control storage: {name}')
            if not bindings and not (reads and writes):
                raise Unclosed(f'application lazy control outside first-init graph: {name}')
            guards.append({'symbol':name,'address':address,'storage':'zero-backed BSS',
                           'binding':'swift_once callback' if bindings else 'inline initializer guard',
                           'callbackSites':[{'pc':pc,'targets':list(targets)} for pc,targets in sorted(bindings)],
                           'readPcs':reads,'writePcs':writes})
    if set(required) - seen:
        raise Unclosed('required application lazy control is missing from linked metadata')
    if not guards:
        raise Unclosed('no application initializer control inventory')
    return guards
