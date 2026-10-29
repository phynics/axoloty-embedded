#!/usr/bin/env python3
# Copyright (c) 2026 Axoloty contributors. Licensed under the MIT License.
"""Offline engine and CLI regressions; no SDK, Docker, network, or ROM blob."""
from __future__ import annotations

from pathlib import Path
import contextlib
import io
import json
import os
import subprocess
import sys
import struct
import tempfile

import first_init_stack as d
from initialization_interval import Engine, Unclosed


class FixtureProgram:
    """Instruction fixtures isolate dataflow from the pinned decoding boundary."""
    rom_memcpy = -1

    def __init__(self, bodies):
        self.instructions = {}
        self.functions = {}
        for name,start,lines in bodies:
            fn = d.Function(name,start,4*len(lines))
            for i,(mnemonic,ops,target) in enumerate(lines):
                pc = start+4*i
                ins = d.Instruction(pc,mnemonic,ops,target,f'{pc:x}: {mnemonic} {ops}',4,'00000013')
                fn.instructions.append(ins)
                self.instructions[pc] = ins
            self.functions[start] = fn

    def function(self, address):
        for fn in self.functions.values():
            if fn.start <= address < fn.end and address in self.instructions:
                return fn
        raise Unclosed('missing/truncated fixture body')

    def read(self, address, size):
        return None


def tiny_elf():
    """A real ELF with two same-address aliases and a ten-byte function."""
    instructions = bytes.fromhex('130101fc130101048280')
    strings = b'\0short\0full\0'
    sections = b'\0.text\0.symtab\0.strtab\0.shstrtab\0'
    image = bytearray(0x100)
    image[:16] = b'\x7fELF\x01\x01\x01'+bytes(9)
    image.extend(instructions)
    symoff = len(image)
    symbols = bytes(16)+struct.pack('<IIIBBH',1,0x1000,2,0x12,0,1)+struct.pack('<IIIBBH',7,0x1000,10,0x12,0,1)
    image.extend(symbols)
    stroff = len(image);image.extend(strings)
    namesoff = len(image);image.extend(sections)
    shoff = len(image)
    rows = [bytes(40),struct.pack('<IIIIIIIIII',1,1,6,0x1000,0x100,10,0,0,2,0),
            struct.pack('<IIIIIIIIII',7,2,0,0,symoff,len(symbols),3,1,4,16),
            struct.pack('<IIIIIIIIII',15,3,0,0,stroff,len(strings),0,0,1,0),
            struct.pack('<IIIIIIIIII',23,3,0,0,namesoff,len(sections),0,0,1,0)]
    image.extend(b''.join(rows))
    struct.pack_into('<HHIIIIIHHHHHH',image,16,2,243,1,0,0,shoff,0,52,0,0,40,5,4)
    return bytes(image)


def run_tests():
    checks = []
    def check(name, bodies, expected=None, rejected=None, **options):
        engine = Engine(FixtureProgram(bodies))
        try:
            result,_path = engine.analyze(bodies[0][1],**options)
        except Unclosed as error:
            if rejected is None or rejected not in str(error):
                raise AssertionError(f'{name}: unexpected rejection {error}') from error
        else:
            assert rejected is None and result == expected,(name,result,expected,rejected)
        checks.append(name)
    ret = ('c.jr','x1',None)
    frame64 = [('addi','x2,x2,-64',None),('addi','x2,x2,64',None),ret]
    check('simultaneous callers, siblings do not sum',[
        ('root',0x1000,[('addi','x2,x2,-32',None),('sw','x1,28(x2)',None),
                        ('jal','x1,0x2000',0x2000),('jal','x1,0x2000',0x2000),
                        ('lw','x1,28(x2)',None),('addi','x2,x2,32',None),ret]),
        ('leaf',0x2000,frame64)],96)
    check('external jal x0 retains large tail',[
        ('root',0x1000,[('jal','x0,0x2000',0x2000)]),('large',0x2000,frame64)],64)
    check('compressed frame and alternate-link outlined continuation',[
        ('root',0x1000,[('c.addi16sp','x2,-16',None),('jal','x5,0x2000',0x2000),
                       ('c.addi16sp','x2,16',None),ret]),
        ('outlined',0x2000,[('c.jr','x5',None)])],16)
    check('unknown dynamic SP', [('root',0x1000,[('add','x2,x2,x10',None),ret])],rejected='dynamic SP')
    check('stack access below allocated frame', [('root',0x1000,[('sw','x0,-128(x2)',None),ret])],rejected='below allocated stack')
    check('unknown SP alignment', [('root',0x1000,[('andi','x2,x2,-32',None),ret])],rejected='dynamic SP')
    check('unknown return link', [('root',0x1000,[('c.mv','x1,x10',None),ret])],rejected='unknown indirect')
    check('unknown indirect callback', [('root',0x1000,[('c.jalr','x11',None),ret])],rejected='unknown indirect')
    check('recursion', [('root',0x1000,[('jal','x1,0x1000',0x1000),ret])],rejected='recursive')
    check('self tail recursion with sibling return', [('root',0x1000,[('c.beqz','x10,0x1008',0x1008),('jal','x0,0x1000',0x1000),ret])],rejected='recursive')
    check('unsupported opcode', [('root',0x1000,[('made.up','x10',None),ret])],rejected='unsupported instruction')
    check('exception return is not an ordinary return', [('root',0x1000,[('mret','',None),ret])],rejected='unsupported instruction')
    check('truncated branch target', [('root',0x1000,[('c.j','0x1008',0x1008),ret])],rejected='missing/truncated')
    check('trap scope is explicit', [('root',0x1000,[('c.beqz','x10,0x1008',0x1008),ret,('c.unimp','',None)])],0)
    check('branch skips callback definition',[
        ('root',0x1000,[('c.addi16sp','x2,-16',None),('sw','x1,12(x2)',None),
                       ('c.beqz','x10,0x1010',0x1010),('lui','x11,0x3',None),
                       ('jal','x1,0x2000',0x2000),('lw','x1,12(x2)',None),('c.addi16sp','x2,16',None),ret]),
        ('swift_once',0x2000,[('c.jalr','x11',None),ret]),('callback',0x3000,[ret])],rejected='callback')
    check('compressed call clobbers callback register',[
        ('root',0x1000,[('lui','x11,0x3',None),('c.jal','0x4000',0x4000),('jal','x1,0x2000',0x2000),ret]),
        ('swift_once',0x2000,[('c.jalr','x11',None),ret]),('callback',0x3000,[ret]),('clobber',0x4000,[ret])],rejected='callback')
    check('begin dominance, not ascending PCs',[
        ('root',0x1000,[('c.beqz','x10,0x1008',0x1008),('jal','x1,0x2000',0x2000),
                       ('jal','x1,0x3000',0x3000),('jal','x1,0x4000',0x4000),ret]),
        ('begin',0x2000,[ret]),('hook',0x3000,[ret]),('end',0x4000,[ret])],
        rejected='order violation',skip_calls=True,stages=(0x2000,0x3000,0x4000))
    check('hook cannot return without end',[
        ('root',0x1000,[('c.addi','x2,-16',None),('sw','x1,12(x2)',None),
                       ('jal','x1,0x2000',0x2000),('jal','x1,0x3000',0x3000),
                       ('lw','x1,12(x2)',None),('c.addi','x2,16',None),ret]),
        ('begin',0x2000,[ret]),('hook',0x3000,[ret]),('end',0x4000,[ret])],
        rejected='without trace end',skip_calls=True,stages=(0x2000,0x3000,0x4000))
    dispatch = [('c.li','x6,3',None),('bgeu','x6,x12,0x1010',0x1010),
                ('andi','x12,x12,3',None),('c.j','0x1010',0x1010),
                ('sub','x13,x6,x12',None),('slli','x13,x13,2',None),
                ('auipc','x5,0',None),('c.add','x13,x5',None),
                ('jalr','x0,12(x13)',None),('c.nop','',None),
                ('c.nop','',None),('c.nop','',None),ret]
    check('bounded computed dispatch from unsigned CFG refinement', [('root',0x1000,dispatch)],0)
    escaped = list(dispatch);escaped[8] = ('jalr','x0,14(x13)',None)
    check('computed dispatch to mid-instruction rejects', [('root',0x1000,escaped)],rejected='missing/truncated')
    check('saved-link intra-body subroutine continuation', [('root',0x1000,[
        ('c.mv','x5,x1',None),('auipc','x13,0',None),('addi','x13,x13,24',None),
        ('jalr','x1,0(x13)',None),('c.mv','x1,x5',None),ret,('c.nop','',None),ret])],0)
    # Exercise the production Program's reached-body validator with real ELF
    # bytes. No ROM blob or fake semantic decoder is installed in the repo.
    from initialization_interval import Program
    data=tiny_elf()
    symbols='1000 0002 T short\n1000 000a T full\n'
    text='1000: fc010113 addi x2,x2,-64\n1004 <interior-label>:\n1004: 04010113 addi x2,x2,64\n1008: 8082 c.jr x1\n'
    def bound_program(body_text):
        functions,names=d.parse_symbols(symbols)
        d.parse_disassembly(body_text,functions,names)
        program=Program.__new__(Program)
        program.functions=functions;program.names=names
        program.instructions={ins.address:ins for fn in functions.values() for ins in fn.instructions}
        program.origins={0x1000:(data,symbols,'fixture')}
        program.owners={};program.validated=set()
        program.executable=d.elf32_riscv_image(data)[1]
        program.rows=d.elf32_riscv_image(data)[0]
        program.sections=[];program.rom_memcpy=-1
        return program
    assert Engine(bound_program(text)).analyze(0x1000)[0] == 64
    for broken in (text.replace('1004: 04010113 addi x2,x2,64\n',''),
                   text.replace('1008: 8082 c.jr x1\n',''),
                   text.replace('fc010113','ff010113')):
        try:
            bound_program(broken).function(0x1000)
        except d.InputBindingError:
            pass
        else:
            raise AssertionError('ELF byte/extent mismatch accepted')
    checks.append('actual ELF largest-alias extent, interior label, omission and encoding negatives')
    from initialization_interval import classify_application_guards
    guard_program=FixtureProgram([('root',0x1000,[ret])])
    guard_program.rows=[('$e10__idf_mainfixture_Wz',0x5000,4,1,'.bss',8)]
    guard_engine=Engine(guard_program)
    guard_engine.callback_bindings={(0x1100,(0x5000,),(0x2000,))}
    assert classify_application_guards(guard_program,guard_engine,('$e10__idf_mainfixture_Wz',))[0]['binding']=='swift_once callback'
    guard_engine.callback_bindings=set()
    for access in (set(),{(0x1000,'lw',0x5000,4)},{(0x1004,'sw',0x5000,4)}):
        guard_engine.accesses=access
        try: classify_application_guards(guard_program,guard_engine,('$e10__idf_mainfixture_Wz',))
        except Unclosed: pass
        else: raise AssertionError('uncovered lazy control accepted')
    guard_engine.accesses={(0x1000,'lw',0x5000,4),(0x1004,'sw',0x5000,4)}
    assert classify_application_guards(guard_program,guard_engine,('$e10__idf_mainfixture_Wz',))[0]['binding']=='inline initializer guard'
    guard_program.rows.append(('$e10__idf_maintransport_Wz',0x6000,4,1,'.bss',8))
    assert len(classify_application_guards(guard_program,guard_engine,('$e10__idf_mainfixture_Wz',)))==1
    checks.append('app lazy controls require exact binding; shared transport globals remain outside scope')
    from final_init_proof import first_epoch,ProofInputError,validate_provenance,OUTPUT_NAMES
    completion = json.dumps({'runId':'embedded-swift-smoke-v2','caseId':'completion','status':'completed'}).encode()+b'\r\n'
    epoch = b'Executing action: monitor\r\nESP-ROM:esp32c6\r\nAXOLOTY_HEAP_CAL_V1,case=zero\r\n'+completion+b'AXOLOTY_HEAP_CAL_V1,invalid-after-completion\r\n'
    raw = epoch+b'ESP-ROM:esp32c6\r\n'+completion
    selected,boundary = first_epoch(raw)
    assert selected == epoch and boundary['endByteExclusive']==len(epoch)
    assert b'invalid-after-completion' in selected
    checks.append('epoch includes all calibration rows before next reset')
    for raw in (b'ESP-ROM:first\nAXOLOTY_HEAP_CAL_V1,truncated\nESP-ROM:second\n'+completion,
                b'AXOLOTY_HEAP_CAL_V1,truncated\n'):
        try:
            first_epoch(raw)
        except ProofInputError:
            pass
        else:
            raise AssertionError('truncated first epoch was replaced by a later completion')
    checks.append('truncated first epoch rejects later PASS')
    valid = {'status':'passed','firmware':{'dirty':False,'sourceCopied':False,'revision':'a'*40},
             'core':{'dirty':False,'sha':'b'*40},'artifact':{'sha256':'bin'}}
    validate_provenance(valid,'bin',{'core':{'revision':'b'*40}})
    for mutation in ('a'*40,'not-a-commit-but-still-forty-characters!!!'):
        try:
            validate_provenance(valid,'bin',{'core':{'revision':mutation}})
        except ProofInputError:
            pass
        else:
            raise AssertionError('foreign Core lock accepted')
    checks.append('Core provenance matches authoritative lock')
    script = Path(__file__).with_name('final_init_proof.py')
    with tempfile.TemporaryDirectory(prefix='init-proof-cli-') as directory:
        root = Path(directory)
        out = root/'output';out.mkdir()
        input_file=root/'input';input_file.write_text('input evidence')
        # Exercise the actual parser and filesystem boundary, including errors
        # before a file option, ignored earlier inputs, aliases and hardlinks.
        cases = [(['--output-dir',str(out),'--profile'],True),
                 (['--profile','--output-dir='+str(out)],True),
                 (['--output-dir',str(out),'--self-test=no'],True),
                 (['--output-dir',str(out),'--disassembly','forged-text'],True),
                 (['--output-dir',str(out),'--calibration-csv',str(input_file)],True),
                 (['--output-dir',str(out),'--output-dir'],False),
                 (['--output-dir',str(out),'--help'],False)]
        for args,invalidates in cases:
            receipt=out/'first-init-proof.json';receipt.write_text('old receipt')
            (out/'artifact-sha256.json').write_text('old manifest')
            (out/'foreign.txt').write_text('foreign artifact')
            completed=subprocess.run([sys.executable,str(script),*args],capture_output=True,text=True)
            assert 'Traceback' not in completed.stderr,completed.stderr
            assert receipt.exists() != invalidates,(args,completed.stderr)
            assert (out/'foreign.txt').read_text()=='foreign artifact'
            assert input_file.read_text()=='input evidence'
        for link in ('symlink','hardlink'):
            receipt=out/'first-init-proof.json'
            receipt.unlink(missing_ok=True)
            if link=='symlink': receipt.symlink_to(input_file)
            else: os.link(input_file,receipt)
            completed=subprocess.run([sys.executable,str(script),'--output-dir',str(out),
                                      '--profile','--calibration-csv',str(input_file)],capture_output=True,text=True)
            assert completed.returncode and receipt.exists() and input_file.read_text()=='input evidence'
        assert 'foreign.txt' not in OUTPUT_NAMES
        from final_init_proof import run_disassembler
        native=root/'native';native.mkdir()
        for name in ('riscv32-esp-elf-objdump','riscv32-esp-elf-nm'):
            tool=native/name;tool.write_text('#!/bin/sh\nexit 0\n');tool.chmod(0o755)
        try:
            run_disassembler(input_file,input_file,out,native)
        except ProofInputError as error:
            assert 'pinned tool' in str(error)
        else:
            raise AssertionError('foreign disassembler accepted')
    checks.append('real CLI stale-output, forged text, foreign file and alias preservation')
    print('initialization_interval self-test: '+str(len(checks))+' regression groups passed')
    return checks


if __name__ == '__main__':
    run_tests()
