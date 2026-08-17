---
pre-agent-steps:
  - name: Record API usage before agent
    continue-on-error: true
    uses: actions/github-script@v9.0.0
    with:
      script: |
        const { data } = await github.request("GET /rate_limit");
        const rate = data.resources.core;
        core.exportVariable("GH_API_USED_BEFORE", String(rate.used));
        core.exportVariable("GH_API_REMAINING_BEFORE", String(rate.remaining));
        core.exportVariable("GH_API_RESET_BEFORE", String(rate.reset));

post-steps:
  - name: Report API usage
    if: always()
    continue-on-error: true
    uses: actions/github-script@v9.0.0
    with:
      script: |
        const { data } = await github.request("GET /rate_limit");
        const rate = data.resources.core;
        const resetBefore = Number(process.env.GH_API_RESET_BEFORE);
        const usedBefore = Number(process.env.GH_API_USED_BEFORE);
        const consumed = resetBefore === rate.reset && Number.isFinite(usedBefore)
          ? String(rate.used - usedBefore)
          : "n/a (window reset)";
        await core.summary
          .addDetails("GitHub API Usage", [
            "",
            "",
            "| Consumed | Remaining before | Remaining after | Limit | Reset |",
            "| ---: | ---: | ---: | ---: | --- |",
            `| ${consumed} | ${process.env.GH_API_REMAINING_BEFORE ?? "n/a"} | ${rate.remaining} | ${rate.limit} | ${new Date(rate.reset * 1000).toISOString()} |`,
            "",
            "",
          ].join("\n"))
          .write();
---
