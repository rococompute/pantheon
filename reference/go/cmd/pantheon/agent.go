package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"pantheon/internal/agent"
	"pantheon/internal/client"
	"pantheon/internal/devnet"
)

func cmdAgent(args []string) error {
	fs := flag.NewFlagSet("agent", flag.ExitOnError)
	home := fs.String("home", "", "node home created by `pantheon devnet init`")
	backend := fs.String("backend", "", "claude | codex | grok | muse | scripted:<honest|silent|deny|approve>")
	model := fs.String("model", "", "model name, for backends that take one")
	goalFile := fs.String("goal-file", "", "operator's goal for this agent's terms as leader (overrides agent.json)")
	fs.Parse(args)
	if *home == "" || *backend == "" {
		return fmt.Errorf("--home and --backend are required")
	}
	cfgPath := filepath.Join(*home, "wrapper", "agent.json")
	cfg, err := agent.LoadConfig(cfgPath)
	if err != nil {
		return err
	}
	if *goalFile != "" {
		raw, err := os.ReadFile(*goalFile)
		if err != nil {
			return err
		}
		cfg.Goal = string(raw)
	}
	llm, err := agent.NewBackend(*backend, *model)
	if err != nil {
		return err
	}
	conf, err := devnet.LoadConfig(*home)
	if err != nil {
		return err
	}
	rpc := strings.Replace(conf.RPC.ListenAddress, "tcp://", "http://", 1)
	rpc = strings.Replace(rpc, "0.0.0.0", "127.0.0.1", 1)
	sender, err := client.LoadSender(devnet.AppKeyPath(*home), rpc)
	if err != nil {
		return err
	}
	a, err := agent.New(cfg, sender, llm, filepath.Join(*home, "wrapper", "work"))
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := a.Run(ctx); err != nil && ctx.Err() == nil {
		return err
	}
	return nil
}

// cmdUp runs the whole local network as child processes.
func cmdUp(args []string) error {
	fs := flag.NewFlagSet("up", flag.ExitOnError)
	dir := fs.String("dir", ".devnet", "directory from `pantheon devnet init`")
	backends := fs.String("backends", "claude=claude,codex=codex,grok=grok,muse=scripted:honest", "agent=backend pairs; muse needs MUSE_BASE_URL to run for real")
	goalFile := fs.String("goal-file", "", "operator's goal, used by whichever agent leads")
	fs.Parse(args)
	self, err := os.Executable()
	if err != nil {
		return err
	}
	assigned := map[string]string{}
	for _, pair := range strings.Split(*backends, ",") {
		k, v, ok := strings.Cut(pair, "=")
		if !ok {
			return fmt.Errorf("--backends: %q is not agent=backend", pair)
		}
		assigned[k] = v
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	type proc struct {
		name string
		cmd  *exec.Cmd
	}
	var procs []proc
	spawn := func(name, logName string, args ...string) error {
		home := filepath.Join(*dir, name)
		f, err := os.OpenFile(filepath.Join(home, logName), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return fmt.Errorf("%s: %w (did you run `pantheon devnet init --dir %s`?)", name, err, *dir)
		}
		cmd := exec.Command(self, args...)
		cmd.Stdout, cmd.Stderr = f, f
		if err := cmd.Start(); err != nil {
			return err
		}
		procs = append(procs, proc{name + "/" + logName, cmd})
		return nil
	}
	defer func() {
		for _, p := range procs {
			_ = p.cmd.Process.Signal(syscall.SIGTERM)
		}
		for _, p := range procs {
			_ = p.cmd.Wait()
		}
	}()
	for _, a := range devnet.DefaultAgents {
		if err := spawn(a, "node.log", "node", "--home", filepath.Join(*dir, a)); err != nil {
			return err
		}
	}
	time.Sleep(2 * time.Second)
	for _, a := range devnet.DefaultAgents {
		b := assigned[a]
		if b == "" {
			return fmt.Errorf("--backends has no entry for agent %s", a)
		}
		argv := []string{"agent", "--home", filepath.Join(*dir, a), "--backend", b}
		if *goalFile != "" {
			argv = append(argv, "--goal-file", *goalFile)
		}
		if err := spawn(a, "agent.log", argv...); err != nil {
			return err
		}
	}
	fmt.Printf("running 4 nodes and 4 agents, logs under %s/<agent>/{node,agent}.log\n", *dir)
	rpc := "the RPC address in config.toml"
	if conf, err := devnet.LoadConfig(filepath.Join(*dir, devnet.DefaultAgents[0])); err == nil {
		rpc = strings.Replace(conf.RPC.ListenAddress, "tcp://", "http://", 1)
	}
	fmt.Printf("watch with: %s status --rpc %s\n", os.Args[0], rpc)
	fmt.Println("press Ctrl-C to stop")
	<-ctx.Done()
	fmt.Println("stopping all nodes and agents")
	defer fmt.Println("stopped")
	return nil
}
