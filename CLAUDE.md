## Agent skills

### Issue tracker

Issues live in GitHub Issues at `sunfmin/chessmirror`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Deploy to the phone after every change

Anything that changes what the app does or looks like ends on the phone, without being asked.
Once the screen tests are green and the work is committed:

```bash
cd App && ./deploy.sh        # optional [udid]; defaults to the first connected iPhone
```

It builds Release, installs on the phone and relaunches the app, stamping the build with the
minute it was built. **Report that build number** — 关于 shows the same one, so 「手机上的是不是带
修复的那版」 has an answer.

- It takes minutes: run it in the background, say what is going over, and give the build number
  and one line on what to look at when it lands.
- No phone connected or the phone locked → the script exits with `no connected iPhone found`.
  Say so and stop. Never quietly deploy to a simulator instead.
- The tests come first. The phone is for looking at, not for finding out whether it builds.
