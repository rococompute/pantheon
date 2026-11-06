package devnet

import (
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	cfg "github.com/cometbft/cometbft/config"
	cmtflags "github.com/cometbft/cometbft/libs/cli/flags"
	cmtlog "github.com/cometbft/cometbft/libs/log"
	"github.com/cometbft/cometbft/node"
	"github.com/cometbft/cometbft/p2p"
	"github.com/cometbft/cometbft/privval"
	"github.com/cometbft/cometbft/proxy"
	"github.com/spf13/viper"

	"pantheon/internal/app"
	"pantheon/internal/beacon"
)

// dieWithParent stops test nodes outliving a test binary that panicked, since a
// panic skips its cleanup and would leave them running with their ports held.
func dieWithParent() {
	parent := os.Getppid()
	go func() {
		for os.Getppid() == parent {
			time.Sleep(time.Second)
		}
		os.Exit(1)
	}()
}

// LoadConfig reads a home's config.toml.
func LoadConfig(home string) (*cfg.Config, error) {
	conf := cfg.DefaultConfig()
	v := viper.New()
	v.SetConfigFile(filepath.Join(home, "config", "config.toml"))
	if err := v.ReadInConfig(); err != nil {
		return nil, fmt.Errorf("reading config: %w (was this home created with `pantheon devnet init`?)", err)
	}
	if err := v.Unmarshal(conf); err != nil {
		return nil, err
	}
	conf.SetRoot(home)
	if err := conf.ValidateBasic(); err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}
	return conf, nil
}

// RunNode runs one validator in this process until interrupted. The ABCI app is
// linked in, so there is no separate socket to secure or keep in sync.
func RunNode(home string) error {
	if os.Getenv("PANTHEON_TEST_DIE_WITH_PARENT") != "" {
		dieWithParent()
	}
	conf, err := LoadConfig(home)
	if err != nil {
		return err
	}
	logger := cmtlog.NewTMLogger(cmtlog.NewSyncWriter(os.Stdout))
	logger, err = cmtflags.ParseLogLevel(conf.LogLevel, logger, cfg.DefaultLogLevel)
	if err != nil {
		return err
	}
	var share *beacon.Share
	if raw, err := os.ReadFile(SharePath(home)); err == nil {
		share = &beacon.Share{}
		if err := json.Unmarshal(raw, share); err != nil {
			return fmt.Errorf("parsing %s: %w", SharePath(home), err)
		}
	} else {
		logger.Error("no BLS share found: this node can validate but won't contribute randomness", "path", SharePath(home))
	}
	a, err := app.New(filepath.Join(home, "data", "market"), share, logger.With("module", "market"))
	if err != nil {
		return err
	}
	nodeKey, err := p2p.LoadNodeKey(conf.NodeKeyFile())
	if err != nil {
		return fmt.Errorf("loading node key: %w", err)
	}
	pv := privval.LoadFilePV(conf.PrivValidatorKeyFile(), conf.PrivValidatorStateFile())
	n, err := node.NewNode(conf, pv, nodeKey, proxy.NewLocalClientCreator(a),
		node.DefaultGenesisDocProviderFunc(conf), cfg.DefaultDBProvider,
		node.DefaultMetricsProvider(conf.Instrumentation), logger)
	if err != nil {
		return fmt.Errorf("starting node: %w", err)
	}
	if err := n.Start(); err != nil {
		return fmt.Errorf("starting node: %w", err)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	if n.IsRunning() {
		_ = n.Stop()
		n.Wait()
	}
	return nil
}
