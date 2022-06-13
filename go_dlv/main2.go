package main

import (
	"fmt"
	"os"
	"time"
)

func receiver(msgQueue chan string) {
	sleepDuration := 10
	for {
		select {
		case msg := <-msgQueue:
			fmt.Println("Received:", msg)
			fmt.Println("\"Processing\" the received message for", sleepDuration, "seconds")
			time.Sleep(time.Duration(sleepDuration) * time.Second)
		default:
			fmt.Println("No message received")
		}
	}
}

func sender(msgQueue chan string, identifier int) {
	defer close(msgQueue)
	i := 0
	for {
		msg := fmt.Sprintf("Q%d OK%d", identifier, i)
		fmt.Println("Sending: ", msg)
		msgQueue <- msg
		i++
		time.Sleep(1 * time.Second)
	}
}

func main() {
	fmt.Println("Started dlv example\nPID:", os.Getpid())
	msgQueue := make(chan string, 3)
	go sender(msgQueue, 1)
	go sender(msgQueue, 2)
	go receiver(msgQueue)
	for {
	}
}
