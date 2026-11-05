// esp32agent sees and drives an iPhone through an ESP32 Agent board, over Bluetooth.
package main

import (
	"os"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/app"
)

func main() { os.Exit(app.Main(os.Args[1:])) }
