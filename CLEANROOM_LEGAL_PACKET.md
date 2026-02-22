# Cleanroom Legal Packet (Dirty-Team to Program Owner)

Date: 2026-02-22 (EST)  
Project: 7z cleanroom reimplementation

## 1. Purpose

This document defines legally defensive cleanroom handling controls for implementation from `SPEC_7Z_CLEANROOM.md`.

It is process documentation, not protocol specification.

## 2. Authorized Clean-Team Inputs

Clean-team implementation is authorized to use only:

- `SPEC_7Z_CLEANROOM.md`
- Black-box generated test corpus derived from the spec (if produced)
- Their own original implementation notes and code

### 2.1 Oracle Verification

The clean team is authorized to use the official 7-Zip binary (compiled executable) as a black-box oracle to verify 2-way compatibility. This is limited to running the tool on inputs and observing its standard output, files produced, and exit codes. No reverse-engineering or debugging of the oracle binary is permitted.

## 3. Prohibited Inputs for Clean Team

Clean-team members MUST NOT consult, copy, or summarize:

- 7-Zip source code (C/C++ or other)
- 7-Zip official docs beyond what is already captured in the clean spec package
- Dirty-team raw notes, source excerpts, or reverse-engineering work logs
- Third-party code that is itself derived from 7-Zip implementation internals

## 4. Required Separation Controls

- Personnel separation: clean implementers must not overlap with dirty-team source reviewers.
- Artifact separation: dirty-team working notes remain outside clean-team implementation workspace.
- Communications separation: clean-team receives protocol statements only, not source-derived implementation narratives.
- Audit trail: keep dated records of who had access to dirty materials and who implemented from clean materials.

## 5. Implementation Independence Rules

Clean-team code must:

- Be expressed independently (no copied code/comments/pseudocode).
- Follow protocol-level invariants from the spec, not any inferred original control flow.
- Use any architecture/data structures of their choosing.

## 6. Protocol Behavior Mandate Chosen by Program Owner

Per owner direction, parser policy for unknown typed-size properties is:

- Skip unknown typed-size properties by declared length.
- Continue parsing subsequent fields.
- Emit a non-fatal warning event.

This is already reflected normatively in `SPEC_7Z_CLEANROOM.md`.

## 7. Handoff Checklist

- [x] Clean protocol spec completed (`SPEC_7Z_CLEANROOM.md`).
- [x] Required sections present (1-8 from `CLEANROOM_INSTRUCTIONS.md`).
- [x] Test vectors and mutation failure vectors included.
- [x] Unknown typed-size property policy fixed to skip+warn.
- [ ] Counsel/legal review of process packet.
- [ ] Clean-team acknowledgement of contamination boundaries.

## 8. Attestation Template

Use this text for human sign-off:

"I implemented/assessed this work product using only authorized clean-team inputs listed in `CLEANROOM_LEGAL_PACKET.md`, and I did not consult prohibited dirty-team/source materials."

