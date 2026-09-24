# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Phoenix LiveView, PostgreSQL, published SmolBox ~> 0.2.0. The user chose code-first implementation with final browser review.

## Users

Developers evaluating SmolBox locally and learning to build applications around persistent machines. One operator, one dedicated worker.

## Product Purpose

A runnable development workspace that makes retained machines, commands, files, services and recovery understandable together. Success is completing the documented browser walkthrough with real durable state.

## Positioning

SmolBox owns machine lifetime independently of execution lifetime. The example exposes that distinction and keeps uncertain outcomes visible rather than replaying work.

## Operating Context

A local browser on Linux or macOS, a separately provisioned smolvm 1.17.0 worker, one approved Python image and PostgreSQL. The app must survive its own restart. Worker and database prerequisites are explicit.

## Capabilities and Constraints

Persistent lifecycle, foreground and background commands, browser PTY, approved file transfers, mapped HTTP service, startup workload and console diagnostics. No automatic workload restart policy, application log capture, multi-user hosting, image registry or process supervision. Terminal disconnect does not establish guest termination.

## Brand Commitments

SmolBox name; clear, candid developer language. No invented adoption claims or synthetic state presented as real evidence. New visual decisions are delegated within the user's request for a polished, focused workspace.

## Evidence on Hand

Published 0.2.0 APIs, existing durable-host examples, platform qualification reports and release acceptance scenario. No customer or marketing proof is supplied.

## Product Principles

- Keep durable identity visible and stable.
- Make the next valid action clear.
- Preserve uncertainty and require explicit deletion.
- Demonstrate public APIs in readable code.

## Accessibility & Inclusion

Keyboard-operable controls, visible focus, accessible status/error announcements and responsive browser layouts. Terminal focus must have an escape path.
