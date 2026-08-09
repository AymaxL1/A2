// 17 票 CR 尾款 —— `--purge` 那把 `rm -rf` 的护圈(单元缝)+ unit 里 `A2_HOME` 的反向读法。
//
// ============================================================================
// 为什么这批断言必须在**单元缝**上,而不是 CLI 缝上
// ============================================================================
// 要验的是「`A2_HOME=/`、`A2_HOME=$HOME`、`A2_HOME=/Users` 会被拒」。在 CLI 缝上验它意味着
// **真的用那些值跑一次 purge** —— 而判据一旦有洞,那一跑就是把跑测试的人的家目录删了。
// 所以这里只喂判据本身:`unsafeHomeShape` 是纯函数(连文件系统都不碰),家目录还可以注入,
// 于是"家目录本身/家目录的祖先"两档能在**不依赖跑测试的人是谁**的前提下被验到。
//
// 符号链接那一档非碰盘不可,但它只读不写,而且全在 mktemp 出来的临时目录里。
// 真 `~/.a2`、真 `~` 一个字节都不碰;本文件不起任何进程、不碰 supervisor。

import { afterEach, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { unsafeHomeOnDisk, unsafeHomeShape } from "../src/service/purge-guard.ts";
import {
  renderLaunchdPlist,
  renderSystemdUnit,
  servicePlan,
  unitHomePath,
} from "../src/service/unit.ts";

const workspaces: string[] = [];

async function workspace(): Promise<string> {
  const dir = await mkdtemp("/tmp/a2purge-");
  workspaces.push(dir);
  return dir;
}

afterEach(async () => {
  while (workspaces.length > 0) {
    await rm(workspaces.pop() as string, { recursive: true, force: true });
  }
});

// MARK: - 地板:哪些 $A2_HOME 永远不许被整棵删掉

test("地板:文件系统根被拒(`A2_HOME=/` —— 模板展开丢了一段就是这个形状)", () => {
  const refusal = unsafeHomeShape("/", "/Users/alice");

  expect(refusal?.reason).toBe("filesystem_root");
  expect(refusal?.detail).toContain("/");
});

test("地板:家目录本身被拒(`A2_HOME=$HOME` —— 少写了 /.a2 那半截)", () => {
  const refusal = unsafeHomeShape("/Users/alice", "/Users/alice");

  expect(refusal?.reason).toBe("home_directory");
  // 尾随斜杠是同一个地方,不该因为写法不同就漏掉。
  expect(unsafeHomeShape("/Users/alice/", "/Users/alice")?.reason).toBe("home_directory");
});

test("地板:家目录的祖先被拒(`A2_HOME=/Users` —— 删它等于把所有用户一起端了)", () => {
  expect(unsafeHomeShape("/Users", "/Users/alice")?.reason).toBe("home_ancestor");
  // Linux 那边的同一形状。
  expect(unsafeHomeShape("/home", "/home/alice")?.reason).toBe("home_ancestor");
});

test("地板:相对路径被拒 —— 删除的不变量不依赖上游有没有替我展开过", () => {
  expect(unsafeHomeShape("a2home", "/Users/alice")?.reason).toBe("not_absolute");
  expect(unsafeHomeShape("./.a2", "/Users/alice")?.reason).toBe("not_absolute");
});

test("地板:正常的 home 一律放行(缺省 ~/.a2、临时目录、别的卷)", () => {
  expect(unsafeHomeShape("/Users/alice/.a2", "/Users/alice")).toBeUndefined();
  expect(unsafeHomeShape("/tmp/a2t-xxxx", "/Users/alice")).toBeUndefined();
  expect(unsafeHomeShape("/Volumes/Data/a2", "/Users/alice")).toBeUndefined();
  // 名字以家目录开头但不是它的下级(`/Users/alice2`)—— 前缀比较写错就会在这条上红。
  expect(unsafeHomeShape("/Users/alice2/.a2", "/Users/alice")).toBeUndefined();
});

test("地板:不注入家目录时用真家目录,且真家目录本身被拒(缺省参数没接错)", () => {
  expect(unsafeHomeShape(homedir())?.reason).toBe("home_directory");
  expect(unsafeHomeShape(path.join(homedir(), ".a2"))).toBeUndefined();
});

// MARK: - 符号链接:删链不删树 = 假账

test("symlink home:如实拒绝,并给出链目标(rm -rf 只会删掉链,数据全在那头)", async () => {
  const root = await workspace();
  const real = path.join(root, "real-home");
  const link = path.join(root, "linked-home");
  await mkdir(path.join(real, "run"), { recursive: true });
  await writeFile(path.join(real, "settings.json"), "{}\n");
  await symlink(real, link);

  const refusal = await unsafeHomeOnDisk(link);

  expect(refusal?.reason).toBe("symlink");
  expect(refusal?.linkTarget).toBe(real);
  expect(refusal?.detail).toContain(real);
});

test("dangling symlink 同样如实:链在、目标没了 —— 删它既清不掉数据也证明不了什么", async () => {
  const root = await workspace();
  const link = path.join(root, "linked-home");
  await symlink(path.join(root, "查无此目录"), link);

  const refusal = await unsafeHomeOnDisk(link);

  expect(refusal?.reason).toBe("dangling_symlink");
  expect(refusal?.linkTarget).toBe(path.join(root, "查无此目录"));
});

test("真目录与不存在的路径都放行(前者正常删,后者没什么可删 —— 都不是拒绝的理由)", async () => {
  const root = await workspace();
  const real = path.join(root, "home");
  await mkdir(real, { recursive: true });

  expect(await unsafeHomeOnDisk(real)).toBeUndefined();
  expect(await unsafeHomeOnDisk(path.join(root, "从来没有过"))).toBeUndefined();
});

// MARK: - 反向读法:盘上那份 unit 记着的 A2_HOME(⓪c 交叉核对的事实来源)

test("往返:launchd/systemd 两个渲染器写进去的 A2_HOME 都读得回来(病态路径也是)", () => {
  for (const home of [
    "/Users/alice/.a2",
    "/tmp/带 空格 的/home",
    "/tmp/a&b/home",
    "/tmp/100%%real/home",
    "/tmp/<tag>/home",
  ]) {
    const environment = { A2_HOME: home };
    const plist = renderLaunchdPlist({
      label: "com.a2.kernel",
      programArguments: ["/usr/local/bin/a2", "daemon", "run"],
      environment,
    });
    expect(unitHomePath("launchd", plist)).toBe(home);

    const unit = renderSystemdUnit({
      programArguments: ["/usr/local/bin/a2", "daemon", "run"],
      environment,
    });
    expect(unitHomePath("systemd", unit)).toBe(home);
  }
});

test("往返:真 plan 写出来的 unit(不是手搭的字符串)也读得回同一个 home", () => {
  const home = "/tmp/a2-plan-home";
  const paths = { home, runDir: `${home}/run`, socketPath: `${home}/run/kernel.sock` };
  const env = { HOME: "/Users/alice", XDG_CONFIG_HOME: "/Users/alice/.config" };

  for (const kind of ["launchd", "systemd"] as const) {
    const plan = servicePlan(kind, paths, env);
    expect(unitHomePath(kind, plan.unitContent)).toBe(home);
  }
});

test("解不出就返回 undefined:不是本内核写的 / 被改坏了 —— 绝不猜(那一格的下一步是不可逆删除)", () => {
  expect(unitHomePath("launchd", "<plist><dict></dict></plist>")).toBeUndefined();
  // 有 EnvironmentVariables 但没有 A2_HOME 那一格。
  expect(
    unitHomePath(
      "launchd",
      "<key>EnvironmentVariables</key>\n<dict>\n<key>PATH</key>\n<string>/usr/bin</string>\n</dict>",
    ),
  ).toBeUndefined();
  expect(unitHomePath("systemd", "[Service]\nType=simple\n")).toBeUndefined();
  // 别的环境变量在场时不许张冠李戴。
  expect(unitHomePath("systemd", "Environment=A2_HOMEX=/tmp/x\nEnvironment=OTHER=1\n")).toBeUndefined();
  expect(unitHomePath("systemd", "Environment=OTHER=1\nEnvironment=A2_HOME=/tmp/x\n")).toBe("/tmp/x");
});
